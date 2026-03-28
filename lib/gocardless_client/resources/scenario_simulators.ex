defmodule GoCardlessClient.Resources.ScenarioSimulators do
  @moduledoc """
  GoCardlessClient Scenario Simulators API.

  Scenario Simulators trigger test events in the **sandbox** environment.
  Use them to simulate payment lifecycle changes during development.

  ## Available scenarios

  | Key | Description |
  |-----|-------------|
  | `payment_paid_out` | Payment included in a payout |
  | `payment_failed` | Payment collection failed |
  | `payment_charged_back` | Payment charged back |
  | `mandate_activated` | Mandate is now active |
  | `mandate_failed` | Mandate setup failed |
  | `mandate_expired` | Mandate has expired |
  | `billing_request_fulfilled` | Billing request fulfilled |
  | `billing_request_pending` | Billing request is pending |

  ## Example

      {:ok, _} = GoCardlessClient.Resources.ScenarioSimulators.run(client,
        "payment_paid_out", "PM123"
      )
  """

  alias GoCardlessClient.{Client, Paginator, Resource}

  @resource_key "scenario_simulators"
  @base_path "/scenario_simulators"

  @doc "Creates a new scenario simulators resource."
  @spec create(Client.t(), map(), keyword()) ::
          {:ok, map()} | {:error, GoCardlessClient.APIError.t() | GoCardlessClient.Error.t()}
  def create(%Client{} = client, params, opts \\ []) do
    Resource.post(client, @base_path, @resource_key, params, opts)
  end

  @doc "Retrieves a single scenario simulators by ID."
  @spec get(Client.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, GoCardlessClient.APIError.t() | GoCardlessClient.Error.t()}
  def get(%Client{} = client, id, opts \\ []) do
    Resource.get(client, "#{@base_path}/#{id}", @resource_key, opts)
  end

  @doc "Updates a scenario simulators."
  @spec update(Client.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, GoCardlessClient.APIError.t() | GoCardlessClient.Error.t()}
  def update(%Client{} = client, id, params, opts \\ []) do
    Resource.put(client, "#{@base_path}/#{id}", @resource_key, params, opts)
  end

  @doc "Lists scenario_simulators with optional filter params."
  @spec list(Client.t(), map(), keyword()) ::
          {:ok, %{items: [map()], meta: map()}}
          | {:error, GoCardlessClient.APIError.t() | GoCardlessClient.Error.t()}
  def list(%Client{} = client, params \\ %{}, opts \\ []) do
    Resource.list(client, @base_path, @resource_key, params, opts)
  end

  @doc "Returns a lazy `Stream` over all pages of scenario_simulators."
  @spec stream(Client.t(), map(), keyword()) :: Enumerable.t()
  def stream(%Client{} = client, params \\ %{}, opts \\ []) do
    Paginator.stream(client, @base_path, params, @resource_key, opts)
  end

  @doc "Eagerly collects all scenario_simulators into a list across all pages."
  @spec collect_all(Client.t(), map(), keyword()) ::
          {:ok, [map()]} | {:error, GoCardlessClient.APIError.t() | GoCardlessClient.Error.t()}
  def collect_all(%Client{} = client, params \\ %{}, opts \\ []) do
    Paginator.collect(client, @base_path, params, @resource_key, opts)
  end
end
