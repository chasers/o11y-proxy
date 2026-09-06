defmodule O11yProxy.Router do
  @moduledoc """
  The `/v1/*` HTTP surface from `.plans/01-agent-contract.md`. Phase 1 (skeleton): only
  discovery endpoints are wired to real data (`/v1/sources`, `/v1/sources/:name/schema`,
  `/healthz`, `/openapi.json`, `/metrics`). `/v1/query` and `/v1/context` return a
  structured `not_implemented` error until an adapter exists (Phase 2+) — never a bare
  404 or an unhandled crash, so an agent hitting them gets a real signal either way.
  """

  use Plug.Router
  use Plug.ErrorHandler
  require Logger

  alias O11yProxy.Shaping

  plug(Plug.Telemetry, event_prefix: [:o11y_proxy, :http])
  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["application/json"]
  )

  plug(O11yProxy.Plugs.Auth)
  plug(:dispatch)

  get "/healthz" do
    send_json(conn, 200, O11yProxy.Sources.healthz())
  end

  get "/v1/sources" do
    send_json(conn, 200, %{sources: O11yProxy.Sources.list()})
  end

  get "/v1/sources/:name/schema" do
    case O11yProxy.Sources.schema(name) do
      {:ok, schema} ->
        send_json(conn, 200, schema)

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "not_found", message: "no such source: #{name}"})

      {:error, :not_supported} ->
        send_json(conn, 404, %{
          error: "not_supported",
          message: "source #{name} does not support schema discovery"
        })

      {:error, reason} ->
        send_json(conn, 502, %{error: "schema_error", message: inspect(reason)})
    end
  end

  get "/openapi.json" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, O11yProxy.openapi_spec())
  end

  get "/metrics" do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, TelemetryMetricsPrometheus.Core.scrape())
  end

  post "/v1/query" do
    case O11yProxy.Query.parse(conn.body_params, default_limit: default_limit()) do
      {:ok, query} ->
        handle_query(conn, query)

      {:error, reason} ->
        send_json(conn, 400, %{error: "invalid_query", message: inspect(reason)})
    end
  end

  post "/v1/context" do
    case O11yProxy.Context.resolve(conn.body_params) do
      {:ok, bundle} ->
        send_json(conn, 200, shape_context(bundle))

      {:error, :ambiguous_request} ->
        send_json(conn, 400, %{
          error: "invalid_query",
          message: "give exactly one of trace_id, error_id, or {from, to, service}"
        })

      {:error, :empty_request} ->
        send_json(conn, 400, %{
          error: "invalid_query",
          message: "one of trace_id, error_id, or {from, to, service} is required"
        })

      {:error, reason} ->
        send_json(conn, 400, %{error: "invalid_query", message: inspect(reason)})
    end
  end

  match _ do
    send_json(conn, 404, %{
      error: "not_found",
      message: "no route for #{conn.method} #{conn.request_path}"
    })
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
    Logger.error("unhandled error: #{kind} #{Exception.format(kind, reason, stack)}")
    send_json(conn, 500, %{error: "internal_error", message: "unexpected server error"})
  end

  # Phase 2: single-source only. Fan-out across multiple sources (merge, rank, budget
  # shaping) is Phase 5's "query layer" — see .plans/05-roadmap.md.
  defp handle_query(conn, %{sources: [name]} = query) do
    started = System.monotonic_time(:millisecond)

    case O11yProxy.Sources.run_query(name, query) do
      {:ok, result} ->
        elapsed = System.monotonic_time(:millisecond) - started
        send_json(conn, 200, envelope(name, result, query.mode, elapsed, []))

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "not_found", message: "no such source: #{name}"})

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - started
        error = error_for(name, reason)
        empty = %{records: [], native: "", total: 0}
        send_json(conn, 200, envelope(name, empty, query.mode, elapsed, [error]))
    end
  end

  defp handle_query(conn, %{sources: nil}) do
    send_json(conn, 400, %{
      error: "invalid_query",
      message: "sources is required in Phase 2 (no fan-out yet) — name exactly one source"
    })
  end

  defp handle_query(conn, %{sources: sources}) when length(sources) != 1 do
    send_json(conn, 400, %{
      error: "unsupported",
      message:
        "Phase 2 supports exactly one source in `sources` — fan-out across multiple " <>
          "sources lands in Phase 5 (.plans/05-roadmap.md)"
    })
  end

  defp error_for(name, reason), do: O11yProxy.ResponseError.build(name, reason)

  # Both endpoints funnel through O11yProxy.Shaping before serialization — redaction is
  # security-critical (`.plans/04-cross-cutting.md`) and must not be skippable by adding a
  # new response path.
  #
  # What gets collapsed differs by signal, deliberately:
  #   * `logs` shape at `:sample` budget (redact + elide + collapse duplicates) — repeated
  #     identical log lines are the single largest budget win on real incident data.
  #   * `trace` is redacted and elided but *never* collapsed. Spans in one trace share a
  #     service and severity and often a name (five `SELECT users` spans is normal), so
  #     collapsing would merge them and throw away the per-span timestamps that make a
  #     waterfall readable — on the endpoint that exists to correlate traces.
  #   * the singular `error` is only redacted: it's one object, and its stack trace is the
  #     highest-value payload in the bundle.
  defp shape_context(bundle) do
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

  defp envelope(name, result, mode, elapsed_ms, errors) do
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

  defp default_limit do
    Application.get_env(:o11y_proxy, :defaults, %{limit: 50}).limit
  end

  defp redact_keys do
    Application.get_env(:o11y_proxy, :defaults, %{}) |> Map.get(:redact_keys, [])
  end

  defp byte_ceiling do
    Application.get_env(:o11y_proxy, :defaults, %{}) |> Map.get(:max_bytes, 64_000)
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
