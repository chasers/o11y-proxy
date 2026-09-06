defmodule O11yProxy.Test.FakeBackendTest do
  @moduledoc """
  Self-test for `O11yProxy.BackendCase` (Phase 1, before any real adapter exists).
  Every real adapter's test file (ClickHouse,
  VictoriaMetrics, Sentry, ...) will `use O11yProxy.BackendCase` the same way this does.
  """

  use O11yProxy.BackendCase,
    backend: O11yProxy.Test.FakeBackend,
    valid_config: [table: "fake_logs", allow_raw: false],
    invalid_config: [table: 123, allow_raw: false],
    queries: [
      %O11yProxy.Query{
        signal: :logs,
        from: ~U[2026-09-05 19:00:00Z],
        to: ~U[2026-09-05 20:00:00Z],
        mode: :summary,
        limit: 50
      },
      %O11yProxy.Query{
        signal: :logs,
        from: ~U[2026-09-05 19:45:00Z],
        to: ~U[2026-09-05 20:00:00Z],
        mode: :sample,
        limit: 20
      },
      %O11yProxy.Query{
        signal: :logs,
        from: ~U[2026-09-05 19:45:00Z],
        to: ~U[2026-09-05 20:00:00Z],
        mode: :full,
        limit: 5
      }
    ],
    time_bound?: fn native ->
      String.contains?(native.sql, "BETWEEN") and
        Map.has_key?(native.params, :from) and Map.has_key?(native.params, :to)
    end,
    limit_present?: fn native, query -> String.contains?(native.sql, "LIMIT #{query.limit}") end,
    value_isolated?: fn native, value -> not String.contains?(native.sql, to_string(value)) end
end
