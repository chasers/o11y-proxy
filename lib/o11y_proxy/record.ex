defmodule O11yProxy.Record do
  @moduledoc """
  Canonical log/trace/error record shape every adapter's `execute/2` returns, loosely
  following OpenTelemetry semantic conventions. See `.plans/01-agent-contract.md`.
  """

  @derive Jason.Encoder
  @enforce_keys [:timestamp, :severity, :body, :service, :attributes, :source]
  defstruct [:timestamp, :severity, :body, :service, :trace_id, :span_id, :attributes, :source]

  @type severity :: :trace | :debug | :info | :warn | :error | :fatal

  @type t :: %__MODULE__{
          timestamp: String.t(),
          severity: severity(),
          body: String.t(),
          service: String.t(),
          trace_id: String.t() | nil,
          span_id: String.t() | nil,
          attributes: map(),
          source: String.t()
        }

  @severities [:trace, :debug, :info, :warn, :error, :fatal]

  @spec severities() :: [severity()]
  def severities, do: @severities
end
