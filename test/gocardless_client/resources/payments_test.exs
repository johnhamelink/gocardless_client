defmodule GoCardlessClient.Resources.PaymentsTest do
  use ExUnit.Case, async: true

  import GoCardlessClient.Factory

  alias GoCardlessClient.APIError
  alias GoCardlessClient.FieldError
  alias GoCardlessClient.Paginator
  alias GoCardlessClient.Resources.Payments

  describe "Factory.build(:payment)" do
    test "builds a payment with correct shape" do
      payment = build(:payment)

      assert payment["id"] =~ ~r/\APM/
      assert payment["amount"] == 1500
      assert payment["currency"] == "GBP"
      assert payment["status"] == "pending_submission"
      assert is_map(payment["links"])
      assert Map.has_key?(payment["links"], "mandate")
    end

    test "builds a payment with custom attributes" do
      payment = build(:payment, %{"amount" => 5000, "status" => "paid_out"})

      assert payment["amount"] == 5000
      assert payment["status"] == "paid_out"
    end

    test "builds a list of payments" do
      payments = build_list(3, :payment)

      assert length(payments) == 3
      assert Enum.all?(payments, &(&1["currency"] == "GBP"))
    end
  end

  describe "Payments module functions" do
    test "exports all expected functions" do
      fns = Payments.__info__(:functions) |> Keyword.keys()

      assert :create in fns
      assert :get in fns
      assert :update in fns
      assert :list in fns
      assert :stream in fns
      assert :collect_all in fns
      assert :cancel in fns
      assert :retry in fns
    end
  end

  describe "APIError.from_response/2" do
    test "parses a payment validation error with multiple fields" do
      body = %{
        "error" => %{
          "type" => "validation_failed",
          "code" => 422,
          "message" => "Validation failed",
          "request_id" => "req_abc123",
          "documentation_url" =>
            "https://developer.gocardless.com/api-reference/#validation-failed",
          "errors" => [
            %{
              "field" => "charge_date",
              "message" => "must be on or after 2024-01-20",
              "request_pointer" => "/payments/charge_date"
            },
            %{
              "field" => "amount",
              "message" => "must be greater than 0",
              "request_pointer" => "/payments/amount"
            }
          ]
        }
      }

      err = APIError.from_response(422, body)

      assert err.status == 422
      assert err.type == "validation_failed"
      assert err.request_id == "req_abc123"
      assert length(err.errors) == 2

      charge_date_err = Enum.find(err.errors, &(&1.field == "charge_date"))
      assert charge_date_err.message =~ "2024-01-20"
      assert charge_date_err.request_pointer == "/payments/charge_date"
    end

    test "handles unexpected response body gracefully" do
      err = APIError.from_response(503, "Service Unavailable")
      assert err.status == 503
      assert err.message == "Unexpected response body"
    end
  end

  describe "FieldError.from_map/1" do
    test "maps raw API error fields" do
      raw = %{
        "field" => "amount",
        "message" => "must be greater than 0",
        "request_pointer" => "/payments/amount"
      }

      fe = FieldError.from_map(raw)

      assert fe.field == "amount"
      assert fe.message == "must be greater than 0"
      assert fe.request_pointer == "/payments/amount"
    end
  end

  describe "Paginator.stream/5" do
    test "returns an Enumerable" do
      client = GoCardlessClient.Client.new!(access_token: "tok", max_retries: 0)
      stream = Paginator.stream(client, "/payments", %{}, "payments")

      assert Enumerable.impl_for(stream) != nil
    end

    test "is lazy and does not immediately make HTTP requests" do
      client = GoCardlessClient.Client.new!(access_token: "tok", max_retries: 0)
      _stream = Paginator.stream(client, "/payments", %{status: "paid_out"}, "payments")
      assert true
    end
  end
end
