defmodule O11yProxy.Response do
  @moduledoc """
  Shapes a core result into the response body the agent contract promises — shared by
  every transport.

  This lived inside `O11yProxy.Router` while HTTP was the only way in. It moved out when
  the CLI arrived: redaction and budget shaping are security-relevant, and two transports
  each building their own envelope is exactly how the security-relevant half drifts
  silently. Both the router and
  `O11yProxy.CLI`'s in-process path call these functions, so there is one definition of
  what leaves this program.
  """

  alias O11yProxy.Shaping

  @doc """
  The `POST /v1/query` envelope: shaped records, `meta`, and the (possibly empty) `errors`
  list. `result` is what `O11yProxy.Sources.run_query/3` returns.
  """
  @spec query_envelope(String.t(), map(), atom(), non_neg_integer(), [map()]) :: map()
  def query_envelope(name, result, mode, elapsed_ms, errors) do
    records = Shaping.shape(result.records, mode, redact_keys())

    %{
      data: records,
      meta: %{
        sources_queried: [name],
        elapsed_ms: elapsed_ms,
        truncated: false,
        total_matched: result.total,
        returned: length(records),
        cursor: Map.get(result, :cursor),
        native_queries: %{name => result.native}
      },
      errors: errors
    }
    |> Shaping.enforce_byte_ceiling([:data], byte_ceiling())
  end

  @doc """
  The `POST /v1/context` bundle, shaped for the wire. `bundle` is what
  `O11yProxy.Context.resolve/2` returns.

  What gets collapsed differs by signal, deliberately:

    * `logs` shape at `:sample` budget (redact + elide + collapse duplicates) — repeated
      identical log lines are the single largest budget win on real incident data.
    * `trace` is redacted and elided but *never* collapsed. Spans in one trace share a
      service and severity and often a name (five `SELECT users` spans is normal), so
      collapsing would merge them and throw away the per-span timestamps that make a
      waterfall readable — on the endpoint that exists to correlate traces.
    * the singular `error` is only redacted: it's one object, and its stack trace is the
      highest-value payload in the bundle.
  """
  @spec context_bundle(map()) :: map()
  def context_bundle(bundle) do
    extra = redact_keys()

    %{
      bundle
      | trace: Shaping.shape(bundle.trace, :full, extra) |> Enum.map(&elide(&1)),
        logs: Shaping.shape(bundle.logs, :sample, extra),
        error: shape_error(bundle.error, extra)
    }
    |> recount_returned()
    |> Shaping.enforce_byte_ceiling([:trace, :logs, :metrics], byte_ceiling())
  end

  @doc "Request `limit` fallback, from the `defaults:` config block."
  @spec default_limit() :: pos_integer()
  def default_limit do
    Application.get_env(:o11y_proxy, :defaults, %{limit: 50}).limit
  end

  @doc "Extra attribute keys to redact, on top of `O11yProxy.Shaping`'s built-in list."
  @spec redact_keys() :: [String.t()]
  def redact_keys do
    Application.get_env(:o11y_proxy, :defaults, %{}) |> Map.get(:redact_keys, [])
  end

  @doc "Response byte ceiling before truncation."
  @spec byte_ceiling() :: pos_integer()
  def byte_ceiling do
    Application.get_env(:o11y_proxy, :defaults, %{}) |> Map.get(:max_bytes, 64_000)
  end

  defp elide(%O11yProxy.Record{} = record),
    do: %{record | attributes: Shaping.elide_long_attributes(record.attributes)}

  defp elide(other), do: other

  # Shaping collapses duplicates, so the count computed in O11yProxy.Context (before
  # shaping) can overstate what actually ships. Recount here, where the final lists exist.
  defp recount_returned(bundle) do
    error_count = if bundle.error, do: 1, else: 0
    returned = length(bundle.trace) + length(bundle.logs) + length(bundle.metrics) + error_count
    %{bundle | meta: Map.put(bundle.meta, :returned, returned)}
  end

  defp shape_error(nil, _extra), do: nil

  defp shape_error(%O11yProxy.Record{} = record, extra) do
    %{record | attributes: Shaping.redact(record.attributes, extra)}
  end
end
