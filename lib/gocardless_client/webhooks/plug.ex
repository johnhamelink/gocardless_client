defmodule GoCardlessClient.Webhooks.Plug do
  @moduledoc """
  A Plug that verifies GoCardlessClient webhook signatures and parses events.

  Parsed events are stored in `conn.private[:gocardless_events]` for downstream
  handlers to consume. The raw body is stored in `conn.private[:gocardless_raw_body]`.

  On signature failure the plug **halts** the connection and returns HTTP 401.
  On JSON parse failure it returns HTTP 400.

  ## Setup in Phoenix

  First, ensure the raw body is preserved by configuring `Plug.Parsers` with
  a custom body reader (required because Plug consumes the body by default):

      # In your endpoint.ex:
      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Jason,
        body_reader: {GoCardlessClient.Webhooks.Plug, :read_body, []}

  Then add a pipeline and route in your router:

      pipeline :gocardless_webhooks do
        plug GoCardlessClient.Webhooks.Plug, secret: System.get_env("GOCARDLESS_WEBHOOK_SECRET")
      end

      scope "/webhooks" do
        pipe_through :gocardless_webhooks
        post "/gocardless", MyApp.WebhookController, :handle
      end

  ## In your controller

      def handle(conn, _params) do
        events = conn.private[:gocardless_events]

        Enum.each(events, fn event ->
          case {event["resource_type"], event["action"]} do
            {"payments", "paid_out"} -> handle_payment_paid_out(event)
            {"mandates", "active"}   -> handle_mandate_active(event)
            {"billing_requests", "fulfilled"} -> handle_br_fulfilled(event)
            _ -> :ok
          end
        end)

        send_resp(conn, 200, "")
      end

  ## Options

  - `:secret` (required) — your webhook endpoint secret from the GoCardlessClient dashboard.
  - `:max_body_bytes` — maximum allowed body size in bytes (default: 10 MB).
  """

  import Plug.Conn

  alias GoCardlessClient.Webhooks

  @default_max_bytes 10 * 1024 * 1024
  @raw_body_key :gocardless_raw_body

  @behaviour Plug

  @impl Plug
  def init(opts) do
    secret = Keyword.fetch!(opts, :secret)
    max_bytes = Keyword.get(opts, :max_body_bytes, @default_max_bytes)
    %{secret: secret, max_bytes: max_bytes}
  end

  @impl Plug
  def call(conn, %{secret: secret, max_bytes: _max_bytes}) do
    raw_body = get_raw_body(conn)
    signature = get_signature(conn)

    case Webhooks.parse(raw_body, signature, secret) do
      {:ok, events} ->
        conn
        |> put_private(:gocardless_events, events)
        |> put_private(@raw_body_key, raw_body)

      {:error, :invalid_signature} ->
        conn
        |> send_resp(401, "Invalid webhook signature")
        |> halt()

      {:error, :empty_payload} ->
        conn
        |> send_resp(400, "Empty payload")
        |> halt()

      {:error, _} ->
        conn
        |> send_resp(400, "Invalid webhook payload")
        |> halt()
    end
  end

  @doc """
  Custom body reader for use with `Plug.Parsers`.

  Reads and caches the raw body in `conn.private[:gocardless_raw_body]` before
  Plug.Parsers consumes it, allowing `GoCardlessClient.Webhooks.Plug` to access it later.

  Add to your endpoint.ex:

      plug Plug.Parsers,
        parsers: [:json],
        json_decoder: Jason,
        body_reader: {GoCardlessClient.Webhooks.Plug, :read_body, []}
  """
  # The return type mirrors Plug.Conn.read_body/2: ok, more (chunked), or error.
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:more, binary(), Plug.Conn.t()}
          | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, put_private(conn, @raw_body_key, body)}

      {:more, partial, conn} ->
        {:more, partial, put_private(conn, @raw_body_key, partial)}

      {:error, _} = err ->
        err
    end
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp get_raw_body(conn) do
    conn.private[@raw_body_key] ||
      Map.get(conn, :body_params, "")
      |> then(fn
        body when is_binary(body) -> body
        _other -> ""
      end)
  end

  defp get_signature(conn) do
    conn
    |> get_req_header("webhook-signature")
    |> List.first()
  end
end
