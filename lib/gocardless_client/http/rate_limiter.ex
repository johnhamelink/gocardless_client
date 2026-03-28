defmodule GoCardlessClient.HTTP.RateLimiter do
  @moduledoc """
  ETS-backed rate-limit state tracker.

  Parses `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` headers
  and stores the latest values per environment for observability.
  """

  @table :gocardless_rate_limits

  @doc "Initialises the ETS table. Called by `GoCardlessClient.Application`."
  @spec init() :: :ok
  def init do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Updates rate-limit state from response headers."
  @spec update(GoCardlessClient.Config.t(), [{String.t(), String.t()}]) :: :ok
  def update(config, headers) do
    state = %{
      limit: parse_int(headers, "x-ratelimit-limit"),
      remaining: parse_int(headers, "x-ratelimit-remaining"),
      reset_at: parse_unix(headers, "x-ratelimit-reset")
    }

    :ets.insert(@table, {config.environment, state})
    :ok
  end

  @doc "Returns the most recently observed rate-limit state."
  @spec get(GoCardlessClient.Config.t()) :: map()
  def get(config) do
    case :ets.lookup(@table, config.environment) do
      [{_, state}] -> state
      [] -> %{limit: nil, remaining: nil, reset_at: nil}
    end
  end

  defp parse_int(headers, name) do
    with {_, v} <- List.keyfind(headers, name, 0), {n, ""} <- Integer.parse(v), do: n
  end

  defp parse_unix(headers, name) do
    with n when is_integer(n) <- parse_int(headers, name),
         do: DateTime.from_unix!(n)
  end
end
