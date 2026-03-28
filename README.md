# GoCardlessClient Elixir SDK (`gocardless_client`)

[![Hex.pm](https://img.shields.io/hexpm/v/gocardless_client.svg)](https://hex.pm/packages/gocardless_client)
[![Documentation](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/gocardless_client)
[![CI](https://github.com/iamkanishka/gocardless_client/actions/workflows/ci.yml/badge.svg)](https://github.com/iamkanishka/gocardless_client/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Production-ready Elixir client for the [GoCardlessClient API](https://developer.gocardless.com/api-reference/). Full coverage of all 44 resource endpoints — payments, mandates, billing requests, subscriptions, webhooks, OAuth2, outbound payments, and more.

---

## Features

| Capability | Detail |
|---|---|
| **Complete API** | All 44 GoCardlessClient resource services |
| **Open Banking** | Billing Requests, Bank Authorisations, Institutions |
| **Outbound Payments** | Send money with ECDSA/RSA request signing |
| **OAuth2** | Partner platform auth-URL, token exchange, lookup, disconnect |
| **Resilience** | Exponential backoff + full jitter, respects `Retry-After` |
| **Pagination** | Lazy `Stream` — zero memory pressure on large datasets |
| **Webhooks** | HMAC-SHA256 verification, Phoenix Plug middleware, IP allowlist |
| **Telemetry** | `[:gocardless, :request, :start/stop/exception]` events |
| **Rate limits** | ETS-backed `X-RateLimit-*` tracking, accessible at runtime |
| **Config** | NimbleOptions-validated schema — catches misconfiguration at startup |
| **OTP** | Finch connection pools, supervised under `GoCardlessClient.Supervisor` |

---

## Installation

Add to `mix.exs`:

```elixir
def deps do
  [{:gocardless_client, "~> 1.0"}]
end
```

---

## Configuration

```elixir
# config/config.exs
config :gocardless_client,
  access_token: System.get_env("GOCARDLESS_ACCESS_TOKEN"),
  environment: :sandbox,   # or :live
  timeout: 30_000,
  max_retries: 3
```

### Runtime / per-request configuration

```elixir
# Build a client at runtime
client = GoCardlessClient.Client.new!(access_token: token, environment: :live)

# Override token for a single request (OAuth partner apps)
client = GoCardlessClient.Client.with_token(client, merchant_token)
```

---

## Quick Start

```elixir
client = GoCardlessClient.client!()

# Create a customer
{:ok, customer} = GoCardlessClient.Resources.Customers.create(client, %{
  email: "alice@example.com",
  given_name: "Alice",
  family_name: "Smith",
  country_code: "GB"
})

# Create a customer bank account
{:ok, bank_account} = GoCardlessClient.Resources.CustomerBankAccounts.create(client, %{
  account_holder_name: "Alice Smith",
  account_number: "55779911",
  branch_code: "200000",
  country_code: "GB",
  links: %{customer: customer["id"]}
})

# Create a mandate
{:ok, mandate} = GoCardlessClient.Resources.Mandates.create(client, %{
  scheme: "bacs",
  links: %{customer_bank_account: bank_account["id"]}
})

# Create a payment
{:ok, payment} = GoCardlessClient.Resources.Payments.create(client, %{
  amount: 1500,
  currency: "GBP",
  description: "Monthly subscription",
  links: %{mandate: mandate["id"]}
}, idempotency_key: GoCardlessClient.new_idempotency_key())
```

---

## Pagination

All list endpoints support a lazy `Stream` that transparently fetches pages:

```elixir
# Stream — memory-efficient, fetches as consumed
GoCardlessClient.Resources.Payments.stream(client, %{status: "paid_out"})
|> Stream.filter(&(&1["amount"] > 1000))
|> Stream.each(&reconcile_payment/1)
|> Stream.run()

# Collect all into a list
{:ok, all_customers} = GoCardlessClient.Resources.Customers.collect_all(client)

# Single page with cursor
{:ok, %{items: payments, meta: meta}} =
  GoCardlessClient.Resources.Payments.list(client, %{limit: 50, after: cursor})
next_cursor = get_in(meta, ["cursors", "after"])
```

---

## Error Handling

```elixir
case GoCardlessClient.Resources.Payments.create(client, params) do
  {:ok, payment} ->
    process(payment)

  {:error, %GoCardlessClient.APIError{} = err} ->
    cond do
      GoCardlessClient.APIError.validation_failed?(err) ->
        Enum.each(err.errors, fn fe ->
          Logger.error("field=#{fe.field} message=#{fe.message}")
        end)

      GoCardlessClient.APIError.rate_limited?(err) ->
        Logger.warning("Rate limited. request_id=#{err.request_id}")

      GoCardlessClient.APIError.invalid_state?(err) ->
        Logger.warning("Invalid state: #{err.message}")

      GoCardlessClient.APIError.not_found?(err) ->
        Logger.warning("Resource not found")
    end

  {:error, %GoCardlessClient.Error{reason: :timeout}} ->
    Logger.error("Request timed out")
end
```

---

## Idempotency

```elixir
key = GoCardlessClient.new_idempotency_key()

{:ok, payment} = GoCardlessClient.Resources.Payments.create(client, params,
  idempotency_key: key
)
```

---

## Subscriptions

```elixir
{:ok, sub} = GoCardlessClient.Resources.Subscriptions.create(client, %{
  amount: 2500,
  currency: "GBP",
  name: "Premium Monthly",
  interval_unit: "monthly",
  interval: 1,
  day_of_month: 1,
  links: %{mandate: mandate_id}
})

# Pause for 2 billing cycles
{:ok, _} = GoCardlessClient.Resources.Subscriptions.pause(client, sub["id"], %{pause_cycles: 2})

# Resume
{:ok, _} = GoCardlessClient.Resources.Subscriptions.resume(client, sub["id"])

# Cancel
{:ok, _} = GoCardlessClient.Resources.Subscriptions.cancel(client, sub["id"])
```

---

## Billing Requests (Open Banking / Pay by Bank)

```elixir
# One-off instant bank payment
{:ok, br} = GoCardlessClient.Resources.BillingRequests.create(client, %{
  payment_request: %{
    amount: 5000,
    currency: "GBP",
    description: "Order #1234"
  }
})

{:ok, flow} = GoCardlessClient.Resources.BillingRequestFlows.create(client, %{
  redirect_uri: "https://example.com/payment-complete",
  links: %{billing_request: br["id"]}
})

# Redirect customer to flow["authorisation_url"]
```

---

## Redirect Flows (Hosted Mandate Setup)

```elixir
session_token = GoCardlessClient.new_idempotency_key()

{:ok, flow} = GoCardlessClient.Resources.RedirectFlows.create(client, %{
  description: "Set up your Direct Debit",
  session_token: session_token,
  success_redirect_url: "https://example.com/mandate-confirmed",
  scheme: "bacs"
})

# Redirect customer to flow["redirect_url"]

# On return:
{:ok, completed} = GoCardlessClient.Resources.RedirectFlows.complete(client,
  flow["id"],
  session_token
)
mandate_id = get_in(completed, ["links", "mandate"])
```

---

## Webhooks

### Verification

```elixir
secret = System.get_env("GOCARDLESS_WEBHOOK_SECRET")

case GoCardlessClient.Webhooks.parse(raw_body, signature, secret) do
  {:ok, events} ->
    Enum.each(events, &handle_event/1)

  {:error, :invalid_signature} ->
    Logger.warning("Invalid webhook signature")

  {:error, :empty_payload} ->
    Logger.warning("Empty webhook payload")
end
```

### Phoenix Plug (recommended)

In `endpoint.ex`:

```elixir
plug Plug.Parsers,
  parsers: [:json],
  json_decoder: Jason,
  body_reader: {GoCardlessClient.Webhooks.Plug, :read_body, []}
```

In `router.ex`:

```elixir
pipeline :gocardless_webhooks do
  plug GoCardlessClient.Webhooks.Plug, secret: System.get_env("GOCARDLESS_WEBHOOK_SECRET")
end

scope "/webhooks" do
  pipe_through :gocardless_webhooks
  post "/gocardless", MyApp.WebhookController, :handle
end
```

In your controller:

```elixir
def handle(conn, _params) do
  events = conn.private[:gocardless_events]

  Enum.each(events, fn event ->
    case {event["resource_type"], event["action"]} do
      {"payments", "paid_out"}           -> handle_payment_paid_out(event)
      {"mandates", "active"}             -> handle_mandate_active(event)
      {"billing_requests", "fulfilled"}  -> handle_br_fulfilled(event)
      {"subscriptions", "cancelled"}     -> handle_sub_cancelled(event)
      _ -> :ok
    end
  end)

  send_resp(conn, 200, "")
end
```

---

## OAuth2 (Partner Platforms)

```elixir
config = %{
  client_id: System.get_env("GC_CLIENT_ID"),
  client_secret: System.get_env("GC_CLIENT_SECRET"),
  redirect_uri: "https://yourapp.com/oauth/callback",
  environment: :live
}

# Step 1: redirect merchant
auth_url = GoCardlessClient.OAuth.authorise_url(config, scope: "read_write", state: csrf)
redirect(conn, external: auth_url)

# Step 2: exchange code
{:ok, token} = GoCardlessClient.OAuth.exchange_code(config, params["code"])

# Step 3: use merchant token
client = GoCardlessClient.Client.with_token(client, token["access_token"])

# Lookup organisation
{:ok, info} = GoCardlessClient.OAuth.lookup_token(config, token["access_token"])

# Revoke
:ok = GoCardlessClient.OAuth.disconnect(config, token["access_token"])
```

---

## Outbound Payments (Request Signing)

```elixir
signer = GoCardlessClient.Signing.new!(
  key_id: System.get_env("GC_SIGNING_KEY_ID"),
  pem: File.read!("private_key.pem"),
  algorithm: :ecdsa
)

{:ok, payment} = GoCardlessClient.Resources.OutboundPayments.create(client, %{
  amount: 50000,
  currency: "GBP",
  description: "Supplier payment",
  links: %{creditor: creditor_id},
  recipient_bank_account: %{
    account_holder_name: "Acme Ltd",
    account_number: "12345678",
    branch_code: "204514"
  }
}, signer: signer, idempotency_key: GoCardlessClient.new_idempotency_key())
```

---

## Scenario Simulators (Sandbox Only)

```elixir
# Trigger events for testing
{:ok, _} = GoCardlessClient.Resources.ScenarioSimulators.run(client, "payment_paid_out", "PM123")
{:ok, _} = GoCardlessClient.Resources.ScenarioSimulators.run(client, "mandate_activated", "MD456")
{:ok, _} = GoCardlessClient.Resources.ScenarioSimulators.run(client, "billing_request_fulfilled", "BRQ789")
```

---

## Rate Limit State

```elixir
state = GoCardlessClient.rate_limit_state(client)
# => %{limit: 1000, remaining: 950, reset_at: ~U[2024-01-15 10:30:00Z]}
```

---

## Telemetry

The HTTP client emits Telemetry events you can attach to for metrics and tracing:

```elixir
:telemetry.attach_many("gocardless-metrics", [
  [:gocardless, :request, :start],
  [:gocardless, :request, :stop],
  [:gocardless, :request, :exception]
], &MyApp.Telemetry.handle_event/4, nil)
```

Each event carries `%{method: method, url: url, attempt: n}` in its metadata,
and `:stop` adds `%{status: status_code}`.

---

## Running Tests

```bash
mix deps.get
mix test
mix test --cover
mix credo --strict
mix dialyzer
```

---

## License

MIT — see [LICENSE](LICENSE).
