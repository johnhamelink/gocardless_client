defmodule GoCardlessClient.OAuth do
  @moduledoc """
  GoCardlessClient OAuth2 partner integration.

  Partner platforms use OAuth to act on behalf of multiple merchant accounts.

  ## Flow

  1. Build an authorisation URL and redirect the merchant.
  2. GoCardlessClient redirects back with `?code=...`
  3. Exchange the code for an access token.
  4. Use the token to make API calls on behalf of the merchant.

  ## Example

      config = %{
        client_id: System.get_env("GC_CLIENT_ID"),
        client_secret: System.get_env("GC_CLIENT_SECRET"),
        redirect_uri: "https://yourapp.com/oauth/callback",
        environment: :sandbox
      }

      # Step 1 — redirect merchant
      auth_url = GoCardlessClient.OAuth.authorise_url(config,
        scope: "read_write",
        state: csrf_token
      )
      redirect(conn, external: auth_url)

      # Step 2 — on callback
      {:ok, token} = GoCardlessClient.OAuth.exchange_code(config, params["code"])

      # Step 3 — use token
      client = GoCardlessClient.Client.new!(access_token: token["access_token"])
  """

  @sandbox_connect "https://connect-sandbox.gocardless.com"
  @live_connect "https://connect.gocardless.com"
  @sandbox_api "https://api-sandbox.gocardless.com"
  @live_api "https://api.gocardless.com"
  @api_version "2015-07-06"

  @type config :: %{
          required(:client_id) => String.t(),
          required(:client_secret) => String.t(),
          required(:redirect_uri) => String.t(),
          optional(:environment) => :sandbox | :live
        }

  @doc """
  Builds the GoCardlessClient OAuth authorisation URL.

  ## Options

  - `:scope` — `"read_write"` (default) or `"read_only"`
  - `:state` — CSRF protection token (recommended)
  - `:initial_view` — `"signup"` or `"login"`
  - `:prefill_email` — pre-fill the merchant's email
  """
  @spec authorise_url(config(), keyword()) :: String.t()
  def authorise_url(config, opts \\ []) do
    base = connect_base(config)

    params =
      %{
        "client_id" => config.client_id,
        "redirect_uri" => config.redirect_uri,
        "response_type" => "code",
        "scope" => Keyword.get(opts, :scope, "read_write")
      }
      |> maybe_put("state", Keyword.get(opts, :state))
      |> maybe_put("initial_view", Keyword.get(opts, :initial_view))
      |> maybe_put("prefill[email]", Keyword.get(opts, :prefill_email))

    base <> "/oauth/authorize?" <> URI.encode_query(params)
  end

  @doc """
  Exchanges an authorisation code for an access token.

  Returns `{:ok, token_response}` where the response contains:
  - `"access_token"` — use with `GoCardlessClient.Client.new!/1`
  - `"token_type"` — `"Bearer"`
  - `"scope"` — granted scope
  - `"organisation_id"` — the merchant's GoCardlessClient organisation ID
  """
  @spec exchange_code(config(), String.t()) ::
          {:ok, map()}
          | {:error, GoCardlessClient.Error.t() | %{status: non_neg_integer(), body: term()}}
  def exchange_code(config, code) do
    body =
      URI.encode_query(%{
        "code" => code,
        "client_id" => config.client_id,
        "client_secret" => config.client_secret,
        "redirect_uri" => config.redirect_uri,
        "grant_type" => "authorization_code"
      })

    post_form(config, "/oauth/access_token", body)
  end

  @doc """
  Looks up which organisation an access token belongs to.

  Returns `{:ok, %{"organisation_id" => ..., "links" => ...}}`.
  """
  @spec lookup_token(config(), String.t()) ::
          {:ok, map()}
          | {:error, GoCardlessClient.Error.t() | %{status: non_neg_integer(), body: term()}}
  def lookup_token(config, access_token) do
    url = api_base(config) <> "/oauth/token_info?token=" <> URI.encode(access_token)

    headers = [
      {"Authorization", "Bearer #{client_credential_token(config)}"},
      {"GoCardlessClient-Version", @api_version},
      {"Accept", "application/json"}
    ]

    get_request(url, headers)
  end

  @doc """
  Revokes an access token, disconnecting the merchant from your app.
  """
  @spec disconnect(config(), String.t()) ::
          :ok | {:error, GoCardlessClient.Error.t() | %{status: non_neg_integer(), body: term()}}
  def disconnect(config, access_token) do
    body =
      URI.encode_query(%{
        "client_id" => config.client_id,
        "client_secret" => config.client_secret,
        "token" => access_token
      })

    case post_form(config, "/oauth/revoke", body) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp connect_base(%{environment: :live}), do: @live_connect
  defp connect_base(_), do: @sandbox_connect

  defp api_base(%{environment: :live}), do: @live_api
  defp api_base(_), do: @sandbox_api

  defp client_credential_token(config), do: "#{config.client_id}:#{config.client_secret}"

  @form_headers [
    {"Content-Type", "application/x-www-form-urlencoded"},
    {"Accept", "application/json"},
    {"GoCardlessClient-Version", @api_version}
  ]

  defp post_form(config, path, body) do
    url = api_base(config) <> path

    Finch.build(:post, url, @form_headers, body)
    |> Finch.request(GoCardlessClient.Finch, receive_timeout: 30_000)
    |> parse_form_response()
  end

  # Parses a Finch response from an OAuth form POST.
  # 200 → decode JSON success; other 2xx/4xx/5xx → structured error; network error → Error.t().
  defp parse_form_response({:ok, %Finch.Response{status: 200, body: resp_body}}) do
    Jason.decode(resp_body)
  end

  defp parse_form_response({:ok, %Finch.Response{status: status, body: resp_body}}) do
    body =
      case Jason.decode(resp_body) do
        {:ok, decoded} -> decoded
        _ -> resp_body
      end

    {:error, %{status: status, body: body}}
  end

  defp parse_form_response({:error, exception}) do
    {:error, GoCardlessClient.Error.network(exception)}
  end

  defp get_request(url, headers) do
    Finch.build(:get, url, headers)
    |> Finch.request(GoCardlessClient.Finch, receive_timeout: 30_000)
    |> parse_get_response()
  end

  defp parse_get_response({:ok, %Finch.Response{status: 200, body: resp_body}}) do
    Jason.decode(resp_body)
  end

  defp parse_get_response({:ok, %Finch.Response{status: status, body: resp_body}}) do
    {:error, %{status: status, body: resp_body}}
  end

  defp parse_get_response({:error, exception}) do
    {:error, GoCardlessClient.Error.network(exception)}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
