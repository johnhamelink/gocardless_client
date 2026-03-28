defmodule GoCardlessClient.ClientTest do
  use ExUnit.Case, async: true

  alias GoCardlessClient.Client

  describe "new/1" do
    test "returns {:ok, client} with valid options" do
      assert {:ok, %Client{config: config}} = Client.new(access_token: "tok")
      assert config.access_token == "tok"
    end

    test "returns {:error, validation_error} with missing token" do
      assert {:error, %NimbleOptions.ValidationError{}} = Client.new([])
    end
  end

  describe "new!/1" do
    test "returns a Client struct" do
      client = Client.new!(access_token: "tok")
      assert %Client{} = client
    end

    test "raises ArgumentError for invalid config" do
      assert_raise ArgumentError, fn -> Client.new!([]) end
    end
  end

  describe "with_token/2" do
    test "returns a new client with the token replaced" do
      client = Client.new!(access_token: "original")
      updated = Client.with_token(client, "new-token")

      assert updated.config.access_token == "new-token"
      assert client.config.access_token == "original"
    end

    test "preserves all other config fields" do
      client = Client.new!(access_token: "tok", environment: :live, timeout: 60_000)
      updated = Client.with_token(client, "new")

      assert updated.config.environment == :live
      assert updated.config.timeout == 60_000
    end
  end

  describe "rate_limit_state/1" do
    test "returns a map with limit, remaining, reset_at keys" do
      client = Client.new!(access_token: "tok")
      state = Client.rate_limit_state(client)

      assert Map.has_key?(state, :limit)
      assert Map.has_key?(state, :remaining)
      assert Map.has_key?(state, :reset_at)
    end
  end
end
