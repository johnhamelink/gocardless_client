defmodule GoCardlessClient.Webhooks do
  @moduledoc """
  GoCardlessClient webhook signature verification and event parsing.

  GoCardlessClient signs every webhook request with HMAC-SHA256. You must verify
  the signature before processing any event to prevent spoofing.

  ## Low-level usage

      case GoCardlessClient.Webhooks.parse(body, signature, webhook_secret) do
        {:ok, events} ->
          Enum.each(events, &handle_event/1)
          conn |> put_status(200) |> text("")

        {:error, :invalid_signature} ->
          conn |> put_status(401) |> text("Forbidden")

        {:error, :empty_payload} ->
          conn |> put_status(400) |> text("Bad Request")
      end

  ## Plug middleware

  Use `GoCardlessClient.Webhooks.Plug` to verify and parse in your Phoenix router:

      pipeline :gocardless_webhooks do
        plug GoCardlessClient.Webhooks.Plug, secret: "your_webhook_secret"
      end

      scope "/webhooks" do
        pipe_through :gocardless_webhooks
        post "/gocardless", MyApp.WebhookController, :handle
      end

  The parsed events are available in `conn.private[:gocardless_events]`.

  ## Event structure

  Each event is a plain map matching the GoCardlessClient API shape:

      %{
        "id" => "EV001",
        "created_at" => "2024-01-15T10:00:00.000Z",
        "resource_type" => "payments",
        "action" => "paid_out",
        "details" => %{"cause" => "payment_paid_out", "description" => "..."},
        "links" => %{"payment" => "PM123"},
        "metadata" => %{}
      }
  """

  # Bitwise is required for &&&, |||, bxor, bsl in ip_in_cidr?/2 and secure_compare/2.
  import Bitwise

  @max_payload_bytes 10 * 1_048_576

  @type event :: map()
  @type parse_error :: :invalid_signature | :empty_payload | :invalid_json | :payload_too_large

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Parses and verifies a GoCardlessClient webhook request body.

  Returns `{:ok, [event]}` or `{:error, reason}`.

  - `body`      — raw request body binary
  - `signature` — value of the `Webhook-Signature` HTTP header
  - `secret`    — your endpoint's webhook secret from the GoCardlessClient dashboard

  ## Example

      body = conn |> Map.get(:body_params) |> Jason.encode!()
      sig  = Plug.Conn.get_req_header(conn, "webhook-signature") |> List.first()

      {:ok, events} = GoCardlessClient.Webhooks.parse(body, sig, "your_secret")
  """
  @spec parse(binary() | nil, String.t(), String.t()) ::
          {:ok, [event()]} | {:error, parse_error()}
  def parse(nil, _signature, _secret), do: {:error, :empty_payload}
  def parse("", _signature, _secret), do: {:error, :empty_payload}

  def parse(body, signature, secret) when is_binary(body) and byte_size(body) > 0 do
    with :ok <- verify_signature(body, signature, secret) do
      decode_events(body)
    end
  end

  @doc """
  Verifies only the HMAC-SHA256 signature without parsing the payload.

  Returns `:ok` or `{:error, :invalid_signature}`.
  """
  @spec verify(binary(), String.t(), String.t()) :: :ok | {:error, :invalid_signature}
  def verify(body, signature, secret) do
    verify_signature(body, signature, secret)
  end

  @doc """
  Generates a new cryptographically random idempotency key (32 hex chars).

  ## Example

      key = GoCardlessClient.Webhooks.idempotency_key()
      # => "4a8f3c2b1d9e7f6a..."
  """
  @spec idempotency_key() :: String.t()
  def idempotency_key do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # ── Event type helpers ──────────────────────────────────────────────────

  @doc "Returns `true` if the event resource_type is \"payments\"."
  @spec payment_event?(event()) :: boolean()
  def payment_event?(%{"resource_type" => "payments"}), do: true
  def payment_event?(_), do: false

  @doc "Returns `true` if the event resource_type is \"mandates\"."
  @spec mandate_event?(event()) :: boolean()
  def mandate_event?(%{"resource_type" => "mandates"}), do: true
  def mandate_event?(_), do: false

  @doc "Returns `true` if the event resource_type is \"subscriptions\"."
  @spec subscription_event?(event()) :: boolean()
  def subscription_event?(%{"resource_type" => "subscriptions"}), do: true
  def subscription_event?(_), do: false

  @doc "Returns `true` if the event resource_type is \"payouts\"."
  @spec payout_event?(event()) :: boolean()
  def payout_event?(%{"resource_type" => "payouts"}), do: true
  def payout_event?(_), do: false

  @doc "Returns `true` if the event resource_type is \"refunds\"."
  @spec refund_event?(event()) :: boolean()
  def refund_event?(%{"resource_type" => "refunds"}), do: true
  def refund_event?(_), do: false

  @doc "Returns `true` if the event resource_type is \"billing_requests\"."
  @spec billing_request_event?(event()) :: boolean()
  def billing_request_event?(%{"resource_type" => "billing_requests"}), do: true
  def billing_request_event?(_), do: false

  @doc "Returns `true` if the event action matches `action`."
  @spec action?(event(), String.t()) :: boolean()
  def action?(%{"action" => a}, action), do: a == action
  def action?(_, _), do: false

  # ── GoCardlessClient IP allowlist ──────────────────────────────────────────────

  @doc """
  Returns `true` if `ip` is within the GoCardlessClient webhook IP allowlist.

  Use as a defence-in-depth layer alongside signature verification.
  See https://developer.gocardless.com/api-reference/#overview-approved-ip-addresses
  for the current list.
  """
  @spec gocardless_ip?(String.t()) :: boolean()
  def gocardless_ip?(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, addr} -> Enum.any?(cidrs(), &ip_in_cidr?(addr, &1))
      {:error, _} -> false
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  # All verify_signature/3 clauses grouped together as required by Elixir.
  defp verify_signature(_body, sig, _secret) when not is_binary(sig) do
    {:error, :invalid_signature}
  end

  defp verify_signature(body, signature, secret) do
    expected =
      :crypto.mac(:hmac, :sha256, secret, body)
      |> Base.encode16(case: :lower)

    # Constant-time comparison prevents timing side-channel attacks.
    if secure_compare(expected, signature), do: :ok, else: {:error, :invalid_signature}
  end

  # Constant-time binary comparison using Bitwise XOR accumulation.
  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    a_bytes = :binary.bin_to_list(a)
    b_bytes = :binary.bin_to_list(b)

    diff =
      Enum.zip(a_bytes, b_bytes)
      |> Enum.reduce(0, fn {x, y}, acc -> acc ||| bxor(x, y) end)

    diff == 0
  end

  defp secure_compare(_a, _b), do: false

  defp decode_events(body) when byte_size(body) > @max_payload_bytes do
    {:error, :payload_too_large}
  end

  defp decode_events(body) do
    case Jason.decode(body) do
      {:ok, %{"events" => events}} when is_list(events) -> {:ok, events}
      {:ok, _} -> {:error, :invalid_json}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  # GoCardlessClient webhook IP CIDRs.
  # Source: https://developer.gocardless.com/api-reference/#overview-approved-ip-addresses
  @cidrs [
    {{35, 192, 0, 0}, 14},
    {{35, 196, 0, 0}, 15},
    {{35, 198, 0, 0}, 16},
    {{35, 199, 0, 0}, 16},
    {{35, 200, 0, 0}, 13},
    {{35, 208, 0, 0}, 12},
    {{34, 95, 0, 0}, 17},
    {{34, 101, 0, 0}, 16},
    {{34, 106, 0, 0}, 16},
    {{34, 110, 0, 0}, 15}
  ]

  defp cidrs, do: @cidrs

  defp ip_in_cidr?({a, b, c, d} = _addr, {net_tuple, prefix_len}) do
    ip_int = ip_tuple_to_int({a, b, c, d})
    net_int = ip_tuple_to_int(net_tuple)
    mask = compute_mask(prefix_len)
    band(ip_int, mask) == band(net_int, mask)
  end

  defp ip_in_cidr?(_addr, _cidr), do: false

  defp ip_tuple_to_int({a, b, c, d}) do
    a * 16_777_216 + b * 65_536 + c * 256 + d
  end

  defp compute_mask(prefix_len) do
    band(bsl(0xFFFFFFFF, 32 - prefix_len), 0xFFFFFFFF)
  end
end
