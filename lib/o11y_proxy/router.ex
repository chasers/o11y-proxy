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

  alias O11yProxy.Response

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
    case O11yProxy.Query.parse(conn.body_params, default_limit: Response.default_limit()) do
      {:ok, query} ->
        handle_query(conn, query)

      {:error, reason} ->
        send_json(conn, 400, %{error: "invalid_query", message: inspect(reason)})
    end
  end

  post "/v1/context" do
    case O11yProxy.Context.resolve(conn.body_params) do
      {:ok, bundle} ->
        send_json(conn, 200, Response.context_bundle(bundle))

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
        send_json(conn, 200, Response.query_envelope(name, result, query.mode, elapsed, []))

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "not_found", message: "no such source: #{name}"})

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - started
        error = error_for(name, reason)
        empty = %{records: [], native: "", total: 0}
        send_json(conn, 200, Response.query_envelope(name, empty, query.mode, elapsed, [error]))
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

  # Both data endpoints funnel through O11yProxy.Response before reaching here. Redaction
  # and budget shaping are security-critical (`.plans/04-cross-cutting.md`), so they live
  # in one module the CLI shares rather than in each transport — this one only serializes.
  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
