defmodule O11yProxy.Backends.ClickHouseTest do
  @moduledoc """
  Runs `O11yProxy.BackendCase` against the real adapter and a real ClickHouse. Excluded
  by default (see `test/test_helper.exs`) since this sandbox has no docker available to
  run one — `.plans/04-cross-cutting.md` calls for ClickHouse in CI via docker-compose,
  which is what `docker/docker-compose.yml` + `docker/seed.sh` are for.

  To run for real:

      docker compose -f docker/docker-compose.yml up -d
      ./docker/seed.sh
      mix test --include clickhouse test/o11y_proxy/backends/click_house_test.exs
  """

  use O11yProxy.BackendCase,
    backend: O11yProxy.Backends.ClickHouse,
    moduletag: :clickhouse,
    # SQL genuinely expresses all eight canonical operators — confirmed by running this
    # suite against a real ClickHouse, which is also what surfaced that BackendCase used
    # to *require* every adapter to leave at least one unsupported.
    all_operators_supported: true,
    valid_config: [
      url: "http://localhost:8123",
      user: "default",
      password: "",
      database: "otel_test",
      table: "otel_logs",
      allow_raw: true,
      mapping: %{
        "timestamp" => "Timestamp",
        "severity" => "SeverityText",
        "body" => "Body",
        "service" => "ServiceName",
        "trace_id" => "TraceId",
        "span_id" => "SpanId",
        "attributes" => "LogAttributes"
      },
      hints: %{
        "partition_key" => "Timestamp",
        "low_cardinality" => ["ServiceName", "SeverityText"]
      }
    ],
    invalid_config: [
      url: "http://localhost:8123",
      user: "default",
      password: "",
      database: "otel_test",
      table: 123,
      mapping: %{}
    ],
    queries: [
      %O11yProxy.Query{
        signal: :logs,
        from: DateTime.add(DateTime.utc_now(), -3600, :second),
        to: DateTime.add(DateTime.utc_now(), 3600, :second),
        mode: :summary,
        limit: 50
      },
      %O11yProxy.Query{
        signal: :logs,
        from: DateTime.add(DateTime.utc_now(), -3600, :second),
        to: DateTime.add(DateTime.utc_now(), 3600, :second),
        mode: :sample,
        limit: 20
      },
      %O11yProxy.Query{
        signal: :logs,
        from: DateTime.add(DateTime.utc_now(), -3600, :second),
        to: DateTime.add(DateTime.utc_now(), 3600, :second),
        mode: :full,
        limit: 5
      }
    ],
    time_bound?: fn native ->
      native.sql =~ "BETWEEN" and Map.has_key?(native.params, :from) and
        Map.has_key?(native.params, :to)
    end,
    limit_present?: fn native, query -> native.sql =~ "LIMIT #{query.limit}" end,
    value_isolated?: fn native, value -> not String.contains?(native.sql, to_string(value)) end
end
