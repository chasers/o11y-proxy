defmodule O11yProxy.Router do
  @moduledoc """
  The `/v1/*` HTTP surface from `.plans/01-agent-contract.md`.

  Deliberately thin. Every data endpoint hands its parsed body to
  `O11yProxy.Remote.handle/1` and does nothing but turn the result into a status code —
  routing, validation, shaping and redaction all live behind that one call, which the CLI
  (`.plans/07-cli.md`) enters through as well. Two transports mapping the same façade onto
  their own status conventions is what keeps them from becoming two implementations.

  What stays here is genuinely HTTP: matching, JSON parsing, auth, telemetry, the
  OpenAPI/Prometheus documents, and the status-code table below.
  """

  use Plug.Router
  use Plug.ErrorHandler
  require Logger

  alias O11yProxy.Remote

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
    respond(conn, Remote.handle(%{"command" => "health", "request" => %{}}))
  end

  get "/v1/sources" do
    respond(conn, Remote.handle(%{"command" => "sources", "request" => %{}}))
  end

  get "/v1/sources/:name/schema" do
    respond(conn, Remote.handle(%{"command" => "schema", "request" => %{"source" => name}}))
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
    respond(conn, Remote.handle(%{"command" => "query", "request" => conn.body_params}))
  end

  post "/v1/context" do
    respond(conn, Remote.handle(%{"command" => "context", "request" => conn.body_params}))
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

  # `{:ok, _}` is 200 even when the body carries entries in `errors[]` — a source that
  # failed is a partial answer, and the contract says partial results are the normal path
  # (`.plans/04-cross-cutting.md`). Only a request we could not serve at all gets a 4xx/5xx.
  defp respond(conn, {:ok, body}), do: send_json(conn, 200, body)

  defp respond(conn, {:error, %{error: name} = body}),
    do: send_json(conn, status_for(name), body)

  defp status_for("not_found"), do: 404
  defp status_for("not_supported"), do: 404
  defp status_for("schema_error"), do: 502
  defp status_for(_), do: 400

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
