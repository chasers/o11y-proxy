defmodule O11yProxy.Record do
  @moduledoc """
  Canonical log/trace/error record shape every adapter's `execute/2` returns, loosely
  following OpenTelemetry semantic conventions.
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

  # OTel SeverityText is free-form; SeverityNumber follows the OTel spec's 1-24 range.
  # Unknown/missing values normalize to :info rather than raising — a malformed severity
  # column must never turn into a 500 on an otherwise-good log line.
  @severity_names %{
    "trace" => :trace,
    "debug" => :debug,
    "info" => :info,
    "information" => :info,
    "warn" => :warn,
    "warning" => :warn,
    "error" => :error,
    "fatal" => :fatal,
    "critical" => :fatal
  }

  @doc """
  Normalizes a backend's severity value into the canonical enum.

  Lives here rather than in an adapter because the enum does: any adapter reading a column
  that claims to be an OTel severity needs exactly this mapping, and two copies would
  drift.
  """
  @spec normalize_severity(term()) :: severity()
  def normalize_severity(sev) when is_binary(sev),
    do: Map.get(@severity_names, String.downcase(sev), :info)

  def normalize_severity(sev) when is_integer(sev) do
    cond do
      sev in 1..4 -> :trace
      sev in 5..8 -> :debug
      sev in 9..12 -> :info
      sev in 13..16 -> :warn
      sev in 17..20 -> :error
      sev in 21..24 -> :fatal
      true -> :info
    end
  end

  def normalize_severity(_), do: :info

  @doc """
  Renders a backend's timestamp value as the RFC3339 UTC string `t:t/0` requires.

  `O11yProxy.BackendCase.assert_canonical_record!/1` asserts that shape, so every adapter
  returning rows from a SQL engine funnels through here.
  """
  @spec format_timestamp(term()) :: String.t()
  def format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def format_timestamp(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt) <> "Z"
  def format_timestamp(other), do: to_string(other)
end
