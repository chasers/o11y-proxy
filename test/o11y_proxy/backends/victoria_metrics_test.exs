defmodule O11yProxy.Backends.VictoriaMetricsTest do
  @moduledoc """
  Runs `O11yProxy.BackendCase` against the real adapter and a real VictoriaMetrics.
  Excluded by default (see `test/test_helper.exs`) — no docker in this sandbox.

  To run for real:

      docker compose -f docker/docker-compose.yml up -d
      ./docker/seed-vm.sh
      mix test --include victoriametrics test/o11y_proxy/backends/victoria_metrics_test.exs
  """

  use O11yProxy.BackendCase,
    backend: O11yProxy.Backends.VictoriaMetrics,
    moduletag: :victoriametrics,
    probe_field: "labels.service",
    valid_config: [url: "http://localhost:8428", allow_raw: true],
    invalid_config: [url: 123],
    queries: [
      %O11yProxy.Query{
        signal: :metrics,
        from: DateTime.add(DateTime.utc_now(), -3600, :second),
        to: DateTime.add(DateTime.utc_now(), 3600, :second),
        mode: :summary,
        limit: 50,
        filters: [%O11yProxy.Query.Filter{field: "name", op: :eq, value: "http_requests_total"}]
      },
      %O11yProxy.Query{
        signal: :metrics,
        from: DateTime.add(DateTime.utc_now(), -3600, :second),
        to: DateTime.add(DateTime.utc_now(), 3600, :second),
        mode: :full,
        limit: 20,
        filters: [%O11yProxy.Query.Filter{field: "name", op: :eq, value: "http_requests_total"}]
      }
    ],
    time_bound?: fn native -> Map.has_key?(native, :from) and Map.has_key?(native, :to) end,
    limit_present?: fn native, query -> native.limit == query.limit end,
    value_isolated?: fn native, _value ->
      # A raw substring check is the wrong test here: most of the hostile corpus (e.g. a
      # lone single-quote SQL payload) contains no PromQL-special character and legally
      # appears verbatim inside the one label value — that's containment, not a leak.
      # The real safety property is structural: after removing escaped `\\` and `\"`
      # pairs, exactly two bare `"` should remain — the one matcher's open/close quotes.
      # If a hostile value could forge a second matcher, this count would be higher.
      stripped =
        native.metricsql
        |> String.replace("\\\\", "")
        |> String.replace("\\\"", "")

      stripped |> String.graphemes() |> Enum.count(&(&1 == "\"")) == 2
    end
end
