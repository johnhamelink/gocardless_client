defmodule GoCardlessClient.HTTP.Client do
  @moduledoc """
  Resilient HTTP client over Finch with retries, jitter backoff, and Telemetry.

  - Exponential backoff with full jitter on 429 / 5xx responses
  - Respects `Retry-After` header
  - Emits `[:gocardless, :request, :start | :stop | :exception]` Telemetry events
  - Tracks `X-RateLimit-*` headers via `GoCardlessClient.HTTP.RateLimiter`
  """

  require Logger

  alias GoCardlessClient.{APIError, Config, Error}
  alias GoCardlessClient.HTTP.RateLimiter

  @user_agent "gocardless_client/1.0.0 (Elixir)"
  @version_header "GoCardless-Version"

  @type method :: :get | :post | :put | :patch | :delete
  @type response :: {:ok, map() | list() | nil} | {:error, APIError.t() | Error.t()}

  # Internal request state threaded through the retry loop.
  # Avoids high function arity and keeps individual functions under Credo's
  # ABC-size limit of 25.
  @type req_state :: %{
          config: Config.t(),
          method: method(),
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary() | nil,
          remaining: non_neg_integer(),
          attempt: non_neg_integer()
        }

  @doc """
  Executes an API request with automatic retries and backoff.

  ## Options

  - `:body` — request body map (JSON-encoded before sending)
  - `:idempotency_key` — sets `Idempotency-Key` header
  - `:request_id` — sets `X-Request-ID` correlation header
  - `:access_token` — overrides bearer token for this request only
  - `:signer` — a `GoCardlessClient.Signing` struct for request signing
  """
  # Config is a plain validated map (not a struct), so we match on is_map/1
  # rather than %Config{} which would require a defstruct.
  @spec request(Config.t(), method(), String.t(), keyword()) :: response()
  def request(config, method, path, opts \\ []) when is_map(config) do
    url = Map.get(config, :_base_url_override, Config.base_url(config)) <> path
    body_map = Keyword.get(opts, :body)
    encoded_body = if body_map, do: Jason.encode!(body_map), else: nil
    headers = build_headers(config, opts)
    {final_headers, signed_body} = apply_signing(headers, method, path, encoded_body, opts)

    do_request(%{
      config: config,
      method: method,
      url: url,
      headers: final_headers,
      body: signed_body,
      remaining: config.max_retries + 1,
      attempt: 0
    })
  end

  # ── Retry loop ────────────────────────────────────────────────────────────

  defp do_request(%{remaining: 0}), do: {:error, Error.budget_exhausted()}

  defp do_request(state) do
    start = System.monotonic_time()
    meta = build_meta(state)
    emit_start(state.config, meta)

    state
    |> execute_request()
    |> handle_finch_result(state, meta, System.monotonic_time() - start)
  end

  # Separating Finch result handling from the timing/telemetry logic
  # keeps do_request under the ABC-size limit of 25.
  defp handle_finch_result(finch_result, state, meta, duration) do
    case finch_result do
      {:ok, %Finch.Response{status: status, headers: resp_hdrs, body: resp_body}} ->
        RateLimiter.update(state.config, resp_hdrs)
        emit_stop(state.config, meta, status, duration)
        handle_success_or_retry(state, status, resp_hdrs, resp_body)

      {:error, exception} ->
        emit_exception(state.config, meta, exception, duration)
        handle_network_error(state, exception)
    end
  end

  defp handle_success_or_retry(state, status, resp_hdrs, resp_body) do
    cond do
      status in 200..299 -> {:ok, decode(resp_body)}
      retryable?(state, status) -> retry(state, status, resp_hdrs)
      true -> {:error, APIError.from_response(status, decode(resp_body) || %{})}
    end
  end

  defp retryable?(%{remaining: remaining}, status) do
    remaining > 1 and (status == 429 or status in 500..599)
  end

  defp retry(%{remaining: remaining, attempt: attempt} = state, status, resp_hdrs) do
    sleep = sleep_for(status, resp_hdrs, state.config, attempt)
    log_retry(status, sleep)
    Process.sleep(sleep)
    do_request(%{state | remaining: remaining - 1, attempt: attempt + 1})
  end

  defp sleep_for(429, resp_hdrs, config, attempt), do: retry_after(resp_hdrs, config, attempt)
  defp sleep_for(_status, _hdrs, config, attempt), do: jitter(config, attempt)

  defp log_retry(429, sleep) do
    Logger.warning("[GoCardlessClient] Rate limited (429), waiting #{sleep}ms before retry")
  end

  defp log_retry(status, sleep) do
    Logger.warning("[GoCardlessClient] Server error #{status}, retrying in #{sleep}ms")
  end

  defp handle_network_error(%{remaining: remaining, attempt: attempt} = state, exception) do
    if remaining > 1 do
      sleep = jitter(state.config, attempt)

      Logger.warning(
        "[GoCardlessClient] Network error (retry in #{sleep}ms): #{inspect(exception)}"
      )

      Process.sleep(sleep)
      do_request(%{state | remaining: remaining - 1, attempt: attempt + 1})
    else
      {:error, Error.network(exception)}
    end
  end

  defp execute_request(%{config: config, method: method, url: url, headers: headers, body: body}) do
    Finch.request(
      Finch.build(method, url, headers, body),
      config.finch_name,
      receive_timeout: config.timeout
    )
  end

  # ── Signing ───────────────────────────────────────────────────────────────

  defp apply_signing(headers, method, path, body, opts) do
    case Keyword.get(opts, :signer) do
      nil -> {headers, body}
      signer -> sign_request(headers, signer, method, path, body)
    end
  end

  defp sign_request(headers, signer, method, path, body) do
    body_bin = body || ""

    case GoCardlessClient.Signing.sign_headers(signer, to_string(method), path, body_bin) do
      {:ok, signing_headers} -> {headers ++ signing_headers, body_bin}
      {:error, _} -> {headers, body}
    end
  end

  # ── Headers ───────────────────────────────────────────────────────────────

  defp build_headers(config, opts) do
    token = Keyword.get(opts, :access_token, config.access_token)

    [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"},
      {@version_header, config.api_version},
      {"User-Agent", @user_agent}
    ]
    |> add_header("Idempotency-Key", Keyword.get(opts, :idempotency_key))
    |> add_header("X-Request-ID", Keyword.get(opts, :request_id))
  end

  defp add_header(headers, _name, nil), do: headers
  defp add_header(headers, name, value), do: [{name, value} | headers]

  # ── Telemetry ─────────────────────────────────────────────────────────────

  defp build_meta(%{method: method, url: url, attempt: attempt}) do
    %{method: method, url: url, attempt: attempt + 1}
  end

  defp emit_start(config, meta) do
    :telemetry.execute(
      config.telemetry_prefix ++ [:request, :start],
      %{system_time: System.system_time()},
      meta
    )
  end

  defp emit_stop(config, meta, status, duration) do
    :telemetry.execute(
      config.telemetry_prefix ++ [:request, :stop],
      %{duration: duration},
      Map.put(meta, :status, status)
    )
  end

  defp emit_exception(config, meta, exception, duration) do
    :telemetry.execute(
      config.telemetry_prefix ++ [:request, :exception],
      %{duration: duration},
      Map.put(meta, :error, exception)
    )
  end

  # ── Utilities ─────────────────────────────────────────────────────────────

  defp decode(""), do: nil

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, value} -> value
      _ -> body
    end
  end

  # Full jitter: random value in [0, min(cap, base * 2^attempt)]
  defp jitter(%{base_backoff_ms: base, max_backoff_ms: cap}, attempt) do
    ceiling = min(cap, trunc(base * :math.pow(2, attempt)))
    :rand.uniform(max(ceiling, 1))
  end

  defp retry_after(headers, config, attempt) do
    with {_, value} <- List.keyfind(headers, "retry-after", 0),
         {secs, ""} <- Integer.parse(value) do
      secs * 1_000
    else
      _ -> jitter(config, attempt)
    end
  end
end
