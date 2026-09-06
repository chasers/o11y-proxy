defmodule O11yProxy.Backends.Sentry do
  @moduledoc """
  Errors adapter over the Sentry API. Built third per `.plans/03-adapters.md`'s build
  order — the awkward vendor dialect, by which point `O11yProxy.BackendCase` catches
  drift automatically. Endpoints and shapes below are live-verified against a real org
  (2026-09-06), not just docs — see the Phase 4 spike writeup in `.plans/03-adapters.md`
  and `.plans/05-roadmap.md` for exactly what was confirmed.

  **Only `mode: full` is supported for v1.** Sentry's org-scoped issue-search API
  (`GET /organizations/{org}/issues/`) returns a flat list of issue *groups* — one row
  per distinct error, not per event, and not time-bucketed. There is no live-verified
  path yet to the time-bucketed aggregate `summary` mode promises
  (`.plans/01-agent-contract.md`); building that on an unverified guess about Sentry's
  per-issue stats-sparkline shape would repeat exactly the mistake the Phase 4 spike was
  meant to avoid. Revisit once that shape gets its own spike.

  **`trace_id` costs one extra request per issue.** The issue-list response has no
  `trace_id` — per `01-agent-contract.md`, "any adapter that can surface a trace ID must
  map it, even if it costs an extra field in the query," so `execute/2` follows up with
  `GET .../issues/{id}/events/latest/` per issue (confirmed live: `trace_id` lives at
  `contexts.trace.trace_id`) with bounded concurrency. One issue's enrichment failing
  degrades only that record's `trace_id` to `nil`, never the whole query.
  """

  @behaviour O11yProxy.Backend

  alias O11yProxy.Backends.Sentry.Search
  alias O11yProxy.Record

  @operators [:eq, :contains]

  @impl true
  def config_schema do
    [
      org: [type: :string, required: true, doc: "organization slug"],
      project: [type: :string, required: true, doc: "project slug — one source, one project"],
      token: [
        type: :string,
        required: true,
        doc:
          "org auth token; needs at least org:read (issues/events alone need less, " <>
            "but trace/trace-meta 403 without it — see .plans/03-adapters.md)"
      ],
      base_url: [type: :string, default: "https://sentry.io/api/0"],
      allow_raw: [
        type: :boolean,
        default: false,
        doc: "accept a literal Sentry search query string, bypassing the filter compiler"
      ],
      timeout_ms: [type: :pos_integer, default: 30_000]
    ]
  end

  @impl true
  def init(config) do
    {:ok,
     %{
       base_url: String.trim_trailing(config.base_url, "/"),
       org: config.org,
       project: config.project,
       token: config.token,
       allow_raw: config.allow_raw,
       timeout_ms: config.timeout_ms
     }}
  end

  @impl true
  def capabilities(state) do
    %{
      signals: [:errors],
      operators: @operators,
      modes: [:full],
      raw: state.allow_raw,
      max_window_ms: :infinity
    }
  end

  @impl true
  def schema(_state) do
    {:ok,
     %{
       name: "sentry_issues",
       fields: [
         %{
           canonical: "severity",
           native: "level",
           type: "enum",
           filterable: true,
           cardinality: "low",
           sample_values: ["debug", "info", "warning", "error", "fatal"]
         },
         %{
           canonical: "body",
           native: "title",
           type: "string",
           filterable: true,
           cardinality: "unknown",
           sample_values: []
         },
         %{
           canonical: "trace_id",
           native: "contexts.trace.trace_id",
           type: "string",
           filterable: true,
           cardinality: "unknown",
           sample_values: []
         }
       ]
     }}
  end

  @impl true
  def compile(state, query) do
    if query.raw do
      compile_raw(state, query)
    else
      compile_structured(query)
    end
  end

  defp compile_raw(state, query) do
    if state.allow_raw do
      {:ok, %{query: query.raw, from: query.from, to: query.to, limit: query.limit}}
    else
      {:error, {:raw_not_allowed, "this source does not set allow_raw: true"}}
    end
  end

  defp compile_structured(query) do
    with :ok <- check_operators(query.filters),
         {:ok, search_query} <- Search.build_query(query.filters) do
      {:ok, %{query: search_query, from: query.from, to: query.to, limit: query.limit}}
    end
  end

  defp check_operators(filters) do
    Enum.find_value(filters, :ok, fn f ->
      if f.op in @operators, do: nil, else: {:error, {:unsupported_operator, f.op}}
    end)
  end

  @impl true
  def execute(state, native) do
    params =
      %{
        "project" => state.project,
        "start" => DateTime.to_iso8601(native.from),
        "end" => DateTime.to_iso8601(native.to),
        "limit" => native.limit
      }
      |> maybe_put_query(native.query)

    url = "#{state.base_url}/organizations/#{state.org}/issues/"

    case get_json(state, url, params) do
      {:ok, issues} when is_list(issues) ->
        records =
          issues
          |> Enum.map(&issue_to_record(&1, state))
          |> attach_trace_ids(state)

        {:ok, %{records: records, native: native_text(url, params), total: length(records)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_query(params, ""), do: params
  defp maybe_put_query(params, query), do: Map.put(params, "query", query)

  defp native_text(url, params), do: "GET #{url}?#{URI.encode_query(params)}"

  @impl true
  def health(state) do
    url = "#{state.base_url}/organizations/#{state.org}/issues/"

    case get_json(state, url, %{"project" => state.project, "limit" => 1}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # -- issue -> canonical record ---------------------------------------------------------
  #
  # Pure given a decoded issue map — exercised directly in
  # test/o11y_proxy/backends/sentry/mapping_test.exs against scrubbed captured fixtures,
  # per .plans/05-roadmap.md's "Captured + scrubbed response fixtures".

  @doc false
  @spec issue_to_record(map(), map()) :: Record.t()
  def issue_to_record(issue, state) do
    %Record{
      timestamp: issue["lastSeen"] || issue["firstSeen"],
      severity: normalize_severity(issue["level"]),
      body: issue["title"] || get_in(issue, ["metadata", "value"]) || issue["culprit"] || "",
      service: state.project,
      trace_id: nil,
      span_id: nil,
      attributes: %{
        "issue_id" => issue["id"],
        "short_id" => issue["shortId"],
        "culprit" => issue["culprit"],
        "count" => issue["count"],
        "permalink" => issue["permalink"]
      },
      source: ""
    }
  end

  # Sentry's `level` is already close to canonical, save "warning" -> :warn. Unknown or
  # missing values normalize to :info rather than raising — a malformed level must never
  # turn a real issue into a 500.
  defp normalize_severity(level) when is_binary(level) do
    case String.downcase(level) do
      "debug" -> :debug
      "info" -> :info
      "warning" -> :warn
      "warn" -> :warn
      "error" -> :error
      "fatal" -> :fatal
      "critical" -> :fatal
      _ -> :info
    end
  end

  defp normalize_severity(_), do: :info

  # -- trace_id enrichment ----------------------------------------------------------------

  defp attach_trace_ids(records, state) do
    records
    |> Task.async_stream(&fetch_trace_id(&1, state),
      max_concurrency: 5,
      timeout: state.timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.zip(records)
    |> Enum.map(fn
      {{:ok, trace_id}, record} -> %{record | trace_id: trace_id}
      {_, record} -> record
    end)
  end

  defp fetch_trace_id(%Record{attributes: %{"issue_id" => issue_id}}, state) do
    url = "#{state.base_url}/organizations/#{state.org}/issues/#{issue_id}/events/latest/"

    case get_json(state, url, %{}) do
      {:ok, event} -> get_in(event, ["contexts", "trace", "trace_id"])
      {:error, _} -> nil
    end
  end

  # -- HTTP --------------------------------------------------------------------------------

  defp get_json(state, url, params) do
    opts = [params: params, auth: {:bearer, state.token}, receive_timeout: state.timeout_ms]

    case Req.get(url, opts) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 429} = resp} ->
        {:error, {:rate_limited, retry_after_ms(resp)}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:sentry_error, "HTTP #{status}: #{inspect(body)}"}}

      {:error, exception} ->
        {:error, {:sentry_unreachable, Exception.message(exception)}}
    end
  end

  # Sentry's general API docs don't confirm a `Retry-After` header exists on a 429 (only
  # the separate event-ingest endpoint's docs mention one) — see the Phase 4 spike
  # caveat in .plans/03-adapters.md. Prefer it if present, since it's the most direct
  # signal; fall back to `X-Sentry-Rate-Limit-Reset` (confirmed present on every response,
  # live-verified), which is a unix-seconds window-reset time, not a wait duration, so it
  # still needs converting to a relative offset from now.
  @doc false
  @spec retry_after_ms(map()) :: pos_integer()
  def retry_after_ms(%{headers: headers}) do
    cond do
      value = header(headers, "retry-after") -> parse_seconds(value)
      value = header(headers, "x-sentry-rate-limit-reset") -> reset_offset_ms(value)
      true -> 1_000
    end
  end

  def retry_after_ms(_), do: 1_000

  defp header(headers, name) do
    case Map.get(headers, name) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp parse_seconds(str) do
    case Integer.parse(str) do
      {n, _} -> n * 1_000
      :error -> 1_000
    end
  end

  defp reset_offset_ms(str) do
    case Integer.parse(str) do
      {reset_unix, _} -> max((reset_unix - System.system_time(:second)) * 1_000, 0)
      :error -> 1_000
    end
  end
end
