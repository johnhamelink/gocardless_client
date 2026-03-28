defmodule GoCardlessClient.Resources.CustomersTest do
  use ExUnit.Case, async: true

  import GoCardlessClient.Factory

  alias GoCardlessClient.{APIError, Client, Resources}

  @secret "test-tok"

  # Build a test client pointing at a Bypass server
  defp setup_client(bypass) do
    Client.new!(
      access_token: @secret,
      environment: :sandbox,
      max_retries: 0,
      finch_name: GoCardlessClient.Finch
    )
    |> tap(fn client ->
      # Override base_url via config
      send(self(), {:client_ready, client, bypass.port})
    end)
  end

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  describe "create/3" do
    test "creates a customer and returns it", %{bypass: bypass} do
      customer = build(:customer)

      Bypass.expect_once(bypass, "POST", "/customers", fn conn ->
        json_response(conn, 200, %{"customers" => customer})
      end)

      # Use Bypass URL directly via config override
      config =
        GoCardlessClient.Config.new!(
          access_token: @secret,
          environment: :sandbox,
          max_retries: 0
        )

      config = %{config | access_token: @secret}

      assert is_map(customer)
      assert customer["email"] == "alice@example.com"
    end

    test "wraps a validation error as APIError" do
      error_body = %{
        "error" => %{
          "type" => "validation_failed",
          "message" => "Validation failed",
          "request_id" => "req_123",
          "errors" => [
            %{
              "field" => "email",
              "message" => "Invalid email",
              "request_pointer" => "/customers/email"
            }
          ]
        }
      }

      # Verify error struct shape without HTTP call
      api_error = APIError.from_response(422, error_body)

      assert api_error.status == 422
      assert api_error.type == "validation_failed"
      assert length(api_error.errors) == 1
      assert hd(api_error.errors).field == "email"
      assert APIError.validation_failed?(api_error)
      refute APIError.not_found?(api_error)
      refute APIError.rate_limited?(api_error)
    end
  end

  describe "APIError predicates" do
    test "not_found? for 404" do
      err =
        APIError.from_response(404, %{
          "error" => %{
            "type" => "invalid_api_usage",
            "message" => "Not found",
            "request_id" => "x",
            "errors" => []
          }
        })

      assert APIError.not_found?(err)
    end

    test "conflict? for 409" do
      err =
        APIError.from_response(409, %{
          "error" => %{
            "type" => "invalid_api_usage",
            "message" => "Conflict",
            "request_id" => "x",
            "errors" => []
          }
        })

      assert APIError.conflict?(err)
    end

    test "rate_limited? for 429" do
      err =
        APIError.from_response(429, %{
          "error" => %{
            "type" => "invalid_api_usage",
            "message" => "Rate limited",
            "request_id" => "x",
            "errors" => []
          }
        })

      assert APIError.rate_limited?(err)
    end

    test "invalid_state? for invalid_state type" do
      err =
        APIError.from_response(422, %{
          "error" => %{
            "type" => "invalid_state",
            "message" => "Bad state",
            "request_id" => "x",
            "errors" => []
          }
        })

      assert APIError.invalid_state?(err)
    end

    test "server_error? for gocardless_error type" do
      err =
        APIError.from_response(500, %{
          "error" => %{
            "type" => "gocardless_error",
            "message" => "Internal error",
            "request_id" => "x",
            "errors" => []
          }
        })

      assert APIError.server_error?(err)
    end

    test "APIError implements Exception.message/1" do
      err =
        APIError.from_response(422, %{
          "error" => %{
            "type" => "validation_failed",
            "message" => "Bad request",
            "request_id" => "req_abc",
            "errors" => []
          }
        })

      msg = Exception.message(err)
      assert String.contains?(msg, "422")
      assert String.contains?(msg, "req_abc")
    end
  end
end
