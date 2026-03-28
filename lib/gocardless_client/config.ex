defmodule GoCardlessClient.Config do
  @moduledoc """
  Validated configuration for the GoCardlessClient SDK.

  Set globally in `config.exs` or override per-call:

      config :gocardless_client,
        access_token: System.get_env("GOCARDLESS_ACCESS_TOKEN"),
        environment: :live

      client = GoCardlessClient.Client.new!(access_token: "token")
  """

  @schema NimbleOptions.new!(
            access_token: [
              type: :string,
              required: true,
              doc: "GoCardlessClient API access token."
            ],
            environment: [
              type: {:in, [:sandbox, :live]},
              default: :sandbox,
              doc: "`:sandbox` or `:live`."
            ],
            api_version: [type: :string, default: "2015-07-06", doc: "API version header value."],
            timeout: [type: :pos_integer, default: 30_000, doc: "HTTP timeout in ms."],
            max_retries: [type: :non_neg_integer, default: 3, doc: "Max retries on 429/5xx."],
            base_backoff_ms: [type: :pos_integer, default: 500, doc: "Base backoff in ms."],
            max_backoff_ms: [
              type: :pos_integer,
              default: 30_000,
              doc: "Max backoff ceiling in ms."
            ],
            pool_size: [type: :pos_integer, default: 10, doc: "Finch connection pool size."],
            telemetry_prefix: [
              type: {:list, :atom},
              default: [:gocardless],
              doc: "Telemetry prefix."
            ],
            finch_name: [type: :atom, default: GoCardlessClient.Finch, doc: "Finch process name."]
          )

  @type t :: %{
          required(:access_token) => String.t(),
          required(:environment) => :sandbox | :live,
          required(:api_version) => String.t(),
          required(:timeout) => pos_integer(),
          required(:max_retries) => non_neg_integer(),
          required(:base_backoff_ms) => pos_integer(),
          required(:max_backoff_ms) => pos_integer(),
          required(:pool_size) => pos_integer(),
          required(:telemetry_prefix) => [atom()],
          required(:finch_name) => atom()
        }

  @sandbox_url "https://api-sandbox.gocardless.com"
  @live_url "https://api.gocardless.com"

  @doc "Builds and validates a config map, merging app config with `overrides`."
  @spec new(keyword()) :: {:ok, t()} | {:error, NimbleOptions.ValidationError.t()}
  def new(overrides \\ []) do
    merged = Keyword.merge(Application.get_all_env(:gocardless_client), overrides)

    case NimbleOptions.validate(merged, @schema) do
      {:ok, validated} -> {:ok, Map.new(validated)}
      {:error, _} = err -> err
    end
  end

  @doc "Like `new/1` but raises `ArgumentError` on invalid config."
  @spec new!(keyword()) :: t()
  def new!(overrides \\ []) do
    case new(overrides) do
      {:ok, config} -> config
      {:error, err} -> raise ArgumentError, NimbleOptions.ValidationError.message(err)
    end
  end

  @doc "Returns the base API URL for the given environment."
  @spec base_url(t()) :: String.t()
  def base_url(%{environment: :live}), do: @live_url
  def base_url(_), do: @sandbox_url

  @doc "Returns the NimbleOptions validation schema."
  @spec schema() :: NimbleOptions.t()
  def schema, do: @schema
end
