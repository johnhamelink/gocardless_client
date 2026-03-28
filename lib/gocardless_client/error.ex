defmodule GoCardlessClient.APIError do
  @moduledoc """
  Structured error returned by the GoCardlessClient API.

  ## Fields

  - `:status` — HTTP status code
  - `:type` — `"gocardless_error"`, `"invalid_api_usage"`, `"invalid_state"`, `"validation_failed"`
  - `:message` — human-readable description
  - `:request_id` — GoCardlessClient request ID for support
  - `:documentation_url` — relevant API docs URL
  - `:errors` — list of `GoCardlessClient.FieldError` for validation failures
  """

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          type: String.t() | nil,
          message: String.t() | nil,
          request_id: String.t() | nil,
          documentation_url: String.t() | nil,
          errors: [GoCardlessClient.FieldError.t()],
          raw: map() | nil
        }

  defexception [:status, :type, :message, :request_id, :documentation_url, errors: [], raw: nil]

  @impl true
  def message(%__MODULE__{status: s, message: m, request_id: r}),
    do: "GoCardlessClient API error #{s}: #{m} (request_id=#{r})"

  @doc "Builds an `APIError` from a decoded JSON response body."
  @spec from_response(non_neg_integer(), map() | any()) :: t()
  def from_response(status, %{"error" => err}) do
    %__MODULE__{
      status: status,
      type: err["type"],
      message: err["message"],
      request_id: err["request_id"],
      documentation_url: err["documentation_url"],
      errors: Enum.map(err["errors"] || [], &GoCardlessClient.FieldError.from_map/1),
      raw: err
    }
  end

  def from_response(status, raw),
    do: %__MODULE__{status: status, message: "Unexpected response", raw: raw}

  @doc "Returns `true` if this is a 404 Not Found error."
  @spec not_found?(t()) :: boolean()
  def not_found?(%__MODULE__{status: 404}), do: true
  def not_found?(_), do: false

  @doc "Returns `true` if this is a 409 Conflict error."
  @spec conflict?(t()) :: boolean()
  def conflict?(%__MODULE__{status: 409}), do: true
  def conflict?(_), do: false

  @doc "Returns `true` if this is a 422 validation failure."
  @spec validation_failed?(t()) :: boolean()
  def validation_failed?(%__MODULE__{type: "validation_failed"}), do: true
  def validation_failed?(_), do: false

  @doc "Returns `true` if this is a 429 rate-limited response."
  @spec rate_limited?(t()) :: boolean()
  def rate_limited?(%__MODULE__{status: 429}), do: true
  def rate_limited?(_), do: false

  @doc "Returns `true` if the action cannot be performed in the resource's current state."
  @spec invalid_state?(t()) :: boolean()
  def invalid_state?(%__MODULE__{type: "invalid_state"}), do: true
  def invalid_state?(_), do: false

  @doc "Returns `true` if this is an internal GoCardlessClient server error."
  @spec server_error?(t()) :: boolean()
  def server_error?(%__MODULE__{type: "gocardless_error"}), do: true
  def server_error?(_), do: false
end

defmodule GoCardlessClient.FieldError do
  @moduledoc "Single field-level validation error within a `GoCardlessClient.APIError`."

  @type t :: %__MODULE__{
          field: String.t() | nil,
          message: String.t() | nil,
          request_pointer: String.t() | nil
        }

  defstruct [:field, :message, :request_pointer]

  @spec from_map(map()) :: t()
  def from_map(m),
    do: %__MODULE__{
      field: m["field"],
      message: m["message"],
      request_pointer: m["request_pointer"]
    }
end

defmodule GoCardlessClient.Error do
  @moduledoc "Network-level and SDK-level errors (not API errors)."

  @type reason :: :timeout | :circuit_open | :budget_exhausted | {:network, Exception.t()}
  @type t :: %__MODULE__{reason: reason(), message: String.t()}

  defexception [:reason, :message]

  @impl true
  def message(%__MODULE__{message: m}), do: m

  @spec timeout() :: t()
  def timeout, do: %__MODULE__{reason: :timeout, message: "Request timed out"}

  @spec circuit_open() :: t()
  def circuit_open, do: %__MODULE__{reason: :circuit_open, message: "Circuit breaker open"}

  @spec budget_exhausted() :: t()
  def budget_exhausted,
    do: %__MODULE__{reason: :budget_exhausted, message: "Retry budget exhausted"}

  @spec network(Exception.t()) :: t()
  def network(e), do: %__MODULE__{reason: {:network, e}, message: Exception.message(e)}
end
