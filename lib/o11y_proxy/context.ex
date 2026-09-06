defmodule O11yProxy.Context do
  @moduledoc """
  `POST /v1/context` — the correlation endpoint, and the reason this project exists:
  "one call replaces the six an agent would otherwise make" (`.plans/01-agent-contract.md`).

  Three entry points, exactly one per request (`ContextRequest` in
  `priv/static/openapi.json`):

    * `trace_id` — the main path. Fans out that trace ID across every `:logs`/`:traces`/
      `:errors` source at once, then uses what came back to run a *second* stage against
      `:metrics` sources for the owning service over the trace's own window. Metrics have
      no `trace_id` to filter on, so the service/window has to be *discovered* from stage
      one — that two-stage shape is what makes "and `prod_metrics` for `checkout-api` over
      the trace's window" (`README.md`) actually work.
    * `error_id` — resolves the error first (`Backend.fetch_by_id/2`, currently only
      Sentry), then continues as the `trace_id` path using that error's own trace ID. If
      the error has no trace ID, the bundle is just that error — a real, documented
      partial answer, not a failure.
    * `{from, to, service}` — no anchor entity; correlate everything about one service in
      a window.

  **Partial results are the normal path** (`.plans/04-cross-cutting.md`). Every source is
  queried concurrently under one fan-out deadline; a slow or broken source becomes an
  entry in `errors` while every healthy source still returns data. `error: null` (queried,
  no matching issue) is deliberately distinct from an `errors` entry (the error source
  itself failed) — that distinction was validated in Phase 0's transcripts before any
  adapter existed, and `.plans/05-roadmap.md` calls out keeping it.
  """

  alias O11yProxy.{Query, ResponseError, Sources}
  alias O11yProxy.Query.Filter

  # The caller gives no window for a trace_id/error_id lookup, but ClickHouse (rightly)
  # refuses to run unbounded — so correlation searches back this far by default.
  @default_lookback_seconds 86_400
  @window_padding_seconds 300
  @fan_out_deadline_ms 5_000
  @per_source_timeout_ms 4_000
  @per_source_limit 50

  @doc """
  Resolves one context request into the `ContextResponse` bundle. Returns
  `{:error, :ambiguous_request | :empty_request | {:invalid_time, _}}` for a malformed
  request; anything else — including every source failing — comes back as `{:ok, bundle}`
  with the failures in `bundle.errors`.
  """
  @spec resolve(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve(params, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    with {:ok, entry} <- classify(params),
         {:ok, bundle} <- run(entry, Sources.entries(), opts) do
      {:ok, put_elapsed(bundle, started)}
    end
  end

  @doc """
  Classifies a request into exactly one entry kind. "Exactly one of" is prose-only in the
  OpenAPI schema, so it's enforced here rather than assumed.
  """
  @spec classify(map()) ::
          {:ok,
           {:trace_id, String.t()}
           | {:error_id, String.t()}
           | {:service_window, String.t(), String.t(), String.t()}}
          | {:error, :ambiguous_request | :empty_request}
  def classify(params) do
    trace_id = presence(params["trace_id"])
    error_id = presence(params["error_id"])
    service = presence(params["service"])
    from = presence(params["from"])
    to = presence(params["to"])
    # "Any of service/from/to" is what makes a request *ambiguous* with a trace or error
    # anchor, while only the complete triple is a usable entry — so a lone `service` is
    # neither ambiguous nor valid, and lands on :empty_request below.
    window? = not is_nil(service) or not is_nil(from) or not is_nil(to)

    case Enum.count([not is_nil(trace_id), not is_nil(error_id), window?], & &1) do
      0 -> {:error, :empty_request}
      1 -> entry(trace_id, error_id, {service, from, to})
      _ -> {:error, :ambiguous_request}
    end
  end

  defp entry(trace_id, _error_id, _window) when is_binary(trace_id),
    do: {:ok, {:trace_id, trace_id}}

  defp entry(_trace_id, error_id, _window) when is_binary(error_id),
    do: {:ok, {:error_id, error_id}}

  defp entry(_trace_id, _error_id, {service, from, to})
       when is_binary(service) and is_binary(from) and is_binary(to),
       do: {:ok, {:service_window, service, from, to}}

  # An incomplete window — `service` with no `from`, say. Nothing to correlate on.
  defp entry(_trace_id, _error_id, _window), do: {:error, :empty_request}

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp presence(_), do: nil

  # -- entry kinds --------------------------------------------------------------------

  defp run({:trace_id, trace_id}, sources, opts) do
    {:ok, correlate_trace(trace_id, sources, opts, nil)}
  end

  defp run({:error_id, error_id}, sources, opts) do
    case resolve_error(error_id, sources, opts) do
      {:ok, record} ->
        # The error itself is already in hand; if it carries a trace ID, the rest of the
        # bundle is exactly the trace_id path from there.
        case record.trace_id do
          nil -> {:ok, empty_bundle() |> Map.put(:error, record) |> put_sources([record.source])}
          trace_id -> {:ok, correlate_trace(trace_id, sources, opts, record)}
        end

      # No source had it *and* none of them failed: `error: null` with an empty `errors`
      # — "queried, no such issue", which the contract deliberately distinguishes from
      # "the error source broke".
      {:error, []} ->
        {:ok, empty_bundle()}

      {:error, failures} ->
        errors =
          Enum.map(failures, fn {source_name, reason} ->
            ResponseError.build(source_name, reason)
          end)

        {:ok, %{empty_bundle() | errors: errors}}
    end
  end

  defp run({:service_window, service, from, to}, sources, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, from_dt} <- parse_time(from, now),
         {:ok, to_dt} <- parse_time(to, now) do
      entries =
        Enum.map(sources, fn source ->
          {source, service_query(source, service, from_dt, to_dt, opts)}
        end)

      {:ok, entries |> fan_out(opts) |> assemble()}
    end
  end

  # -- the trace_id correlation, in two stages ------------------------------------------

  defp correlate_trace(trace_id, sources, opts, prefetched_error) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    from = DateTime.add(now, -lookback(opts), :second)

    {metrics_sources, entity_sources} = Enum.split_with(sources, &(&1.signal == :metrics))

    stage_one =
      entity_sources
      |> Enum.map(fn source -> {source, trace_query(source, trace_id, from, now, opts)} end)
      |> fan_out(opts)

    bundle = assemble(stage_one)

    bundle =
      case prefetched_error do
        nil -> bundle
        record -> %{bundle | error: record}
      end

    # The already-resolved error counts as a stage-one result for the purpose of deriving
    # the metrics window: on the `error_id` path it carries a service and a timestamp even
    # when nothing else matched the trace inside the lookback, and skipping metrics in
    # that case would drop the most useful half of the bundle.
    derivable =
      case prefetched_error do
        nil ->
          stage_one

        record ->
          stage_one ++ [{%{name: record.source, signal: :errors}, {:ok, %{records: [record]}}}]
      end

    case derive_window_and_service(derivable) do
      nil ->
        bundle

      {service, window_from, window_to} ->
        metrics =
          metrics_sources
          |> Enum.map(fn source ->
            {source, service_query(source, service, window_from, window_to, opts)}
          end)
          |> fan_out(opts)

        merge(bundle, assemble(metrics))
    end
  end

  # Metrics carry no trace ID, so the service and window for stage two have to come from
  # what stage one actually matched. A trace's spans are the most authoritative source of
  # "which service is this", then logs, then the error.
  @doc false
  @spec derive_window_and_service([tuple()]) :: {String.t(), DateTime.t(), DateTime.t()} | nil
  def derive_window_and_service(results) do
    records =
      results
      |> Enum.flat_map(fn
        {source, {:ok, %{records: records}}} -> Enum.map(records, &{source.signal, &1})
        {_source, _error} -> []
      end)

    with service when is_binary(service) <- pick_service(records),
         [_ | _] = timestamps <- parse_timestamps(records) do
      {earliest, latest} = Enum.min_max_by(timestamps, & &1, DateTime)

      {service, DateTime.add(earliest, -@window_padding_seconds, :second),
       DateTime.add(latest, @window_padding_seconds, :second)}
    else
      _ -> nil
    end
  end

  defp pick_service(records) do
    Enum.find_value([:traces, :logs, :errors], fn signal ->
      Enum.find_value(records, fn
        {^signal, %{service: service}} when is_binary(service) and service != "" -> service
        _ -> nil
      end)
    end)
  end

  defp parse_timestamps(records) do
    Enum.flat_map(records, fn {_signal, record} -> parse_timestamp(record) end)
  end

  defp parse_timestamp(%{timestamp: ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> [dt]
      _ -> []
    end
  end

  defp parse_timestamp(_record), do: []

  # -- per-source query building --------------------------------------------------------

  defp trace_query(source, trace_id, from, to, opts) do
    %Query{
      sources: [source.name],
      signal: source.signal,
      from: from,
      to: to,
      filters: [%Filter{field: "trace_id", op: :eq, value: trace_id}],
      mode: :full,
      limit: limit(opts)
    }
  end

  # Every source gets the same shape; one that can't express a `service` filter (Sentry,
  # whose project *is* the service) simply fails its own `compile/2` and shows up in
  # `errors` — the existing partial-failure machinery, no per-adapter special-casing.
  defp service_query(%{signal: :metrics} = source, service, from, to, opts) do
    %Query{
      sources: [source.name],
      signal: :metrics,
      from: from,
      to: to,
      filters: [%Filter{field: "labels.service", op: :eq, value: service}],
      mode: :full,
      limit: limit(opts)
    }
  end

  defp service_query(source, service, from, to, opts) do
    %Query{
      sources: [source.name],
      signal: source.signal,
      from: from,
      to: to,
      filters: [%Filter{field: "service", op: :eq, value: service}],
      mode: :sample,
      limit: limit(opts)
    }
  end

  # -- fan-out ---------------------------------------------------------------------------

  defp fan_out([], _opts), do: []

  defp fan_out(entries, opts) do
    deadline = Keyword.get(opts, :deadline_ms, @fan_out_deadline_ms)
    per_source = Keyword.get(opts, :per_source_timeout_ms, @per_source_timeout_ms)

    O11yProxy.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      entries,
      fn {source, query} -> Sources.run_query(source.name, query, per_source) end,
      timeout: deadline,
      on_timeout: :kill_task,
      max_concurrency: length(entries),
      ordered: true
    )
    |> Enum.zip(entries)
    |> Enum.map(fn
      {{:ok, result}, {source, _query}} -> {source, result}
      {{:exit, :timeout}, {source, _query}} -> {source, {:error, :timeout}}
      {{:exit, reason}, {source, _query}} -> {source, {:error, reason}}
    end)
  end

  defp resolve_error(error_id, sources, opts) do
    per_source = Keyword.get(opts, :per_source_timeout_ms, @per_source_timeout_ms)

    candidates =
      Enum.filter(sources, fn source ->
        source.signal == :errors and function_exported?(source.backend, :fetch_by_id, 2)
      end)

    # Accumulates every source's failure rather than keeping only the last, so a bundle
    # where two error sources both broke reports both. An open breaker short-circuits
    # here too — otherwise a source already known to be down still burns the full
    # per-source timeout on every error_id request.
    Enum.reduce_while(candidates, {:error, []}, fn source, {:error, failures} ->
      case fetch_source_error(source, error_id, per_source) do
        {:ok, record} -> {:halt, {:ok, %{record | source: source.name}}}
        {:error, :not_found} -> {:cont, {:error, failures}}
        {:error, reason} -> {:cont, {:error, [{source.name, reason} | failures]}}
      end
    end)
    |> case do
      {:ok, _record} = ok -> ok
      # Reversed because failures were prepended: callers report them in source order.
      {:error, failures} -> {:error, Enum.reverse(failures)}
    end
  end

  defp fetch_source_error(source, error_id, timeout) do
    case Sources.breaker_status(source.name) do
      {:open, retry_after_ms} -> {:error, {:circuit_open, retry_after_ms}}
      :closed -> fetch_by_id_in_task(source, error_id, timeout)
    end
  end

  defp fetch_by_id_in_task(source, error_id, timeout) do
    task =
      Task.Supervisor.async_nolink(O11yProxy.TaskSupervisor, fn ->
        source.backend.fetch_by_id(source.state, error_id)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  # -- assembly ---------------------------------------------------------------------------

  defp assemble(results) do
    Enum.reduce(results, empty_bundle(), fn {source, result}, bundle ->
      bundle
      |> put_sources([source.name])
      |> add_result(source, result)
    end)
  end

  defp add_result(bundle, source, {:ok, %{records: records} = result}) do
    bundle
    |> put_native(source.name, result.native)
    |> bump_total(result.total)
    |> place_records(source.signal, records)
  end

  defp add_result(bundle, source, {:error, reason}) do
    %{bundle | errors: bundle.errors ++ [ResponseError.build(source.name, reason)]}
  end

  defp place_records(bundle, :traces, records), do: %{bundle | trace: bundle.trace ++ records}
  defp place_records(bundle, :logs, records), do: %{bundle | logs: bundle.logs ++ records}

  defp place_records(bundle, :metrics, records),
    do: %{bundle | metrics: bundle.metrics ++ records}

  # `error` is singular in the contract — the first matching issue wins; the rest (rare:
  # multiple configured error sources both matching one trace) stay reachable via a
  # normal /v1/query.
  defp place_records(bundle, :errors, records) do
    case {bundle.error, records} do
      {nil, [first | _]} -> %{bundle | error: first}
      _ -> bundle
    end
  end

  defp merge(a, b) do
    %{
      trace: a.trace ++ b.trace,
      logs: a.logs ++ b.logs,
      metrics: a.metrics ++ b.metrics,
      error: a.error || b.error,
      errors: a.errors ++ b.errors,
      meta: %{
        sources_queried: Enum.uniq(a.meta.sources_queried ++ b.meta.sources_queried),
        native_queries: Map.merge(a.meta.native_queries, b.meta.native_queries),
        total_matched: (a.meta.total_matched || 0) + (b.meta.total_matched || 0),
        truncated: false,
        returned: 0,
        cursor: nil,
        elapsed_ms: 0
      }
    }
  end

  defp empty_bundle do
    %{
      trace: [],
      logs: [],
      metrics: [],
      error: nil,
      errors: [],
      meta: %{
        sources_queried: [],
        native_queries: %{},
        total_matched: 0,
        truncated: false,
        returned: 0,
        cursor: nil,
        elapsed_ms: 0
      }
    }
  end

  defp put_sources(bundle, names) do
    update_meta(bundle, :sources_queried, fn queried -> Enum.uniq(queried ++ names) end)
  end

  defp put_native(bundle, name, native) do
    update_meta(bundle, :native_queries, fn natives -> Map.put(natives, name, native) end)
  end

  defp bump_total(bundle, nil), do: bundle

  defp bump_total(bundle, total) do
    update_meta(bundle, :total_matched, fn current -> (current || 0) + total end)
  end

  defp put_elapsed(bundle, started) do
    elapsed = System.monotonic_time(:millisecond) - started

    # `returned` counts everything actually shipped in the bundle, the singular `error`
    # included — a bundle that returns an issue and says "returned: 0" reads as a bug to
    # whoever's on the other end.
    error_count = if bundle.error, do: 1, else: 0

    bundle
    |> update_meta(:elapsed_ms, fn _ -> elapsed end)
    |> update_meta(:returned, fn _ ->
      length(bundle.trace) + length(bundle.logs) + length(bundle.metrics) + error_count
    end)
  end

  defp update_meta(bundle, key, fun), do: %{bundle | meta: Map.update!(bundle.meta, key, fun)}

  defp parse_time(str, now) do
    case Query.Time.parse(str, now) do
      {:ok, dt} -> {:ok, dt}
      {:error, reason} -> {:error, {:invalid_time, reason}}
    end
  end

  defp lookback(opts), do: Keyword.get(opts, :lookback_seconds, @default_lookback_seconds)
  defp limit(opts), do: Keyword.get(opts, :limit, @per_source_limit)
end
