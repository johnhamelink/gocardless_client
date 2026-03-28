defmodule GoCardlessClient.Resources.OutboundPayments do
  @moduledoc """
  GoCardlessClient Outbound Payments API.

  Outbound Payments send money to recipients. They require API request signing
  with an ECDSA P-256 private key registered in your GoCardlessClient dashboard.

  ## Example

      signer = GoCardlessClient.Signing.new!(key_id: "kid", pem: pem_content)

      {:ok, payment} = GoCardlessClient.Resources.OutboundPayments.create(client, %{
        amount: 50000,
        currency: "GBP",
        description: "Supplier payment",
        links: %{creditor: "CR123"},
        recipient_bank_account: %{
          account_holder_name: "Acme Ltd",
          account_number: "12345678",
          branch_code: "204514"
        }
      }, signer: signer, idempotency_key: GoCardlessClient.new_idempotency_key())
  """

  alias GoCardlessClient.{Client, Paginator, Resource}

  @resource_key "outbound_payments"
  @base_path "/outbound_payments"

  @doc "Creates an outbound payment to a recipient. Requires a `:signer` opt."
  @spec create(Client.t(), map(), keyword()) ::
          {:ok, map()} | {:error, GoCardlessClient.APIError.t() | GoCardlessClient.Error.t()}
  def create(%Client{} = client, params, opts \\ []) do
    Resource.post(client, @base_path, @resource_key, params, opts)
  end

  @doc "Retrieves a single outbound payment by ID."
  @spec get(Client.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, GoCardlessClient.APIError.t() | GoCardlessClient.Error.t()}
  def get(%Client{} = client, id, opts \\ []) do
    Resource.get(client, "#{@base_path}/#{id}", @resource_key, opts)
  end

  @doc "Updates an outbound payment's description or metadata."
  @spec update(Client.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, GoCardlessClient.APIError.t() | GoCardlessClient.Error.t()}
  def update(%Client{} = client, id, params, opts \\ []) do
    Resource.put(client, "#{@base_path}/#{id}", @resource_key, params, opts)
  end

  @doc "Returns a page of outbound payments with optional filters."
  @spec list(Client.t(), map(), keyword()) ::
          {:ok, %{items: [map()], meta: map()}}
          | {:error, GoCardlessClient.APIError.t() | GoCardlessClient.Error.t()}
  def list(%Client{} = client, params \\ %{}, opts \\ []) do
    Resource.list(client, @base_path, @resource_key, params, opts)
  end

  @doc "Returns a lazy `Stream` over all pages of outbound payments."
  @spec stream(Client.t(), map(), keyword()) :: Enumerable.t()
  def stream(%Client{} = client, params \\ %{}, opts \\ []) do
    Paginator.stream(client, @base_path, params, @resource_key, opts)
  end

  @doc "Eagerly collects all outbound payments into a list."
  @spec collect_all(Client.t(), map(), keyword()) ::
          {:ok, [map()]} | {:error, GoCardlessClient.APIError.t() | GoCardlessClient.Error.t()}
  def collect_all(%Client{} = client, params \\ %{}, opts \\ []) do
    Paginator.collect(client, @base_path, params, @resource_key, opts)
  end

  @doc "Cancels an outbound payment before it is executed."
  @spec cancel(Client.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, GoCardlessClient.APIError.t() | GoCardlessClient.Error.t()}
  def cancel(%Client{} = client, id, params \\ %{}, opts \\ []) do
    Resource.action(client, "#{@base_path}/#{id}", "cancel", @resource_key, params, opts)
  end

  @doc "Approves an outbound payment that is pending approval."
  @spec approve(Client.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, GoCardlessClient.APIError.t() | GoCardlessClient.Error.t()}
  def approve(%Client{} = client, id, params \\ %{}, opts \\ []) do
    Resource.action(client, "#{@base_path}/#{id}", "approve", @resource_key, params, opts)
  end
end
