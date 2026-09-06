defmodule O11yProxy.Backends.Sentry do
  @moduledoc """
  Errors adapter over the Sentry API. Built third: the awkward vendor dialect, by which
  point `O11yProxy.BackendCase` catches drift automatically. Endpoints and shapes below
  are live-verified against a real org (2026-09-06), not just docs.

  **Only `mode: full` is supported for v1.** Sentry's org-scoped issue-search API
  (`GET /organizations/{org}/issues/`) returns a flat list of issue *groups* — one row
  per distinct error, not per event, and not time-bucketed. There is no live-verified
  path yet to the time-bucketed aggregate `summary` mode promises; building that on an
  unverified guess about Sentry's per-issue stats-sparkline shape would repeat exactly
  the mistake the Phase 4 spike was
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
            "but trace/trace-meta 403 without it)"
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
      with {:ok, cursor} <- decode_cursor(query.cursor) do
        {:ok,
         %{query: query.raw, from: query.from, to: query.to, limit: query.limit, cursor: cursor}}
      end
    else
      {:error, {:raw_not_allowed, "this source does not set allow_raw: true"}}
    end
  end

  defp compile_structured(query) do
    with :ok <- check_operators(query.filters),
         {:ok, search_query} <- Search.build_query(query.filters),
         {:ok, cursor} <- decode_cursor(query.cursor) do
      {:ok,
       %{query: search_query, from: query.from, to: query.to, limit: query.limit, cursor: cursor}}
    end
  end

  # Sentry hands out its own real cursor tokens via the `Link` response header (confirmed
  # live 2026-09-06 against `.../organizations/{org}/issues/`) — this just unwraps our
  # opaque `O11yProxy.Cursor` envelope back to Sentry's native token, which gets passed
  # straight through as the `cursor` query param. A garbage/wrong-backend token is a
  # normal invalid_cursor error, not a crash.
  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(token) do
    case O11yProxy.Cursor.decode(token, "sentry") do
      {:ok, %{"cursor" => native_cursor}} when is_binary(native_cursor) ->
        {:ok, native_cursor}

      # A structurally valid envelope carrying the wrong payload is still just a bad
      # cursor — it must not fall through to a CaseClauseError and a 500.
      _ ->
        {:error, {:invalid_cursor, token}}
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
      |> maybe_put_cursor_param(native.cursor)

    url = "#{state.base_url}/organizations/#{state.org}/issues/"

    case get_with_headers(state, url, params) do
      {:ok, {issues, headers}} when is_list(issues) ->
        records =
          issues
          |> Enum.map(&issue_to_record(&1, state))
          |> attach_trace_ids(state)

        result = %{records: records, native: native_text(url, params), total: length(records)}
        {:ok, maybe_put_cursor(result, headers)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_query(params, ""), do: params
  defp maybe_put_query(params, query), do: Map.put(params, "query", query)

  defp maybe_put_cursor_param(params, nil), do: params
  defp maybe_put_cursor_param(params, cursor), do: Map.put(params, "cursor", cursor)

  defp maybe_put_cursor(result, headers) do
    case parse_next_cursor(headers) do
      nil ->
        result

      native_cursor ->
        Map.put(result, :cursor, O11yProxy.Cursor.encode("sentry", %{"cursor" => native_cursor}))
    end
  end

  defp native_text(url, params), do: "GET #{url}?#{URI.encode_query(params)}"

  @impl true
  def fetch_by_id(state, id) do
    url = "#{state.base_url}/organizations/#{state.org}/issues/#{id}/"

    case get_json(state, url, %{}) do
      {:ok, issue} ->
        record = issue_to_record(issue, state)
        {:ok, %{record | trace_id: fetch_trace_id(record, state)}}

      {:error, {:sentry_error, "HTTP 404" <> _}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
  # test/o11y_proxy/backends/sentry/mapping_test.exs against scrubbed captured fixtures.

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
    case get_with_headers(state, url, params) do
      {:ok, {body, _headers}} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_with_headers(state, url, params) do
    opts = [params: params, auth: {:bearer, state.token}, receive_timeout: state.timeout_ms]

    case Req.get(url, opts) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        {:ok, {body, headers}}

      {:ok, %{status: 429} = resp} ->
        {:error, {:rate_limited, retry_after_ms(resp)}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:sentry_error, "HTTP #{status}: #{inspect(body)}"}}

      {:error, exception} ->
        {:error, {:sentry_unreachable, Exception.message(exception)}}
    end
  end

  # Sentry's issue-list pagination is a real `Link` response header (RFC 5988-shaped),
  # confirmed live 2026-09-06:
  #   <...&cursor=X>; rel="previous"; results="false"; cursor="X",
  #   <...&cursor=Y>; rel="next"; results="true"; cursor="Y"
  # Only the `rel="next"` segment matters, and only when `results="true"` — `"false"`
  # means Sentry itself confirms there's nothing more in that direction, so no cursor
  # should be handed back (an agent paging on a truthy cursor would just get an empty
  # page back, wasting a call).
  @link_next_re ~r/<[^>]*>;\s*rel="next";\s*results="(true|false)";\s*cursor="([^"]+)"/

  @doc false
  @spec parse_next_cursor(map()) :: String.t() | nil
  def parse_next_cursor(headers) do
    with link when is_binary(link) <- header(headers, "link"),
         [_, "true", cursor] <- Regex.run(@link_next_re, link) do
      cursor
    else
      _ -> nil
    end
  end

  # Sentry's general API docs don't confirm a `Retry-After` header exists on a 429 (only
  # the separate event-ingest endpoint's docs mention one). Prefer it if present, since
  # it's the most direct signal; fall back to `X-Sentry-Rate-Limit-Reset` (confirmed
  # present on every response,
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
