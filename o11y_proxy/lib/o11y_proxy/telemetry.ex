defmodule O11yProxy.Telemetry do
  @moduledoc """
  Self-observability — dogfooding, and the fastest way to find out the proxy itself is
  the slow part. See "Self-observability" in `.plans/04-cross-cutting.md`.

  Event names adapters and the query layer are expected to emit as those pieces are
  built (Phase 2+): `[:o11y_proxy, :query, :compile | :execute]`,
  `[:o11y_proxy, :cache, :hit | :miss]`, `[:o11y_proxy, :breaker, :state_change]`.
  HTTP request timing is already wired via `Plug.Telemetry` in `O11yProxy.Router`.
  """

  import Telemetry.Metrics

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      counter("o11y_proxy.http.request.count",
        event_name: [:o11y_proxy, :http, :stop],
        tag_values: &http_tags/1,
        tags: [:method, :status]
      ),
      distribution("o11y_proxy.http.request.duration.milliseconds",
        event_name: [:o11y_proxy, :http, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tag_values: &http_tags/1,
        tags: [:method, :status],
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000]]
      ),
      counter("o11y_proxy.query.compile.count", event_name: [:o11y_proxy, :query, :compile]),
      counter("o11y_proxy.query.execute.count", event_name: [:o11y_proxy, :query, :execute]),
      counter("o11y_proxy.cache.hit.count", event_name: [:o11y_proxy, :cache, :hit]),
      counter("o11y_proxy.cache.miss.count", event_name: [:o11y_proxy, :cache, :miss]),
      counter("o11y_proxy.breaker.state_change.count",
        event_name: [:o11y_proxy, :breaker, :state_change]
      )
    ]
  end

  defp http_tags(%{conn: conn}) do
    %{method: conn.method, status: conn.status}
  end
end
