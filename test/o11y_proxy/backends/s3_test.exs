defmodule O11yProxy.Backends.S3Test do
  @moduledoc """
  Runs `O11yProxy.BackendCase` against the real adapter and a real DuckDB, over the
  hive-partitioned Parquet fixture in `test/fixtures/s3/`.

  Unlike the other three adapter suites this one is **not** excluded by default, and that
  is deliberate. DuckDB is embedded, `parquet` is statically linked into libduckdb, and
  the fixture is a local directory — so there is no service to stand up and no network
  call to make. `CONTRIBUTING.md` warns that "green in CI does not mean the adapters
  work"; for this adapter it now means rather more than that.

  What this suite cannot cover is the object-storage half: `httpfs`, `CREATE SECRET`, and
  gzipped NDJSON. That lives in `O11yProxy.Backends.S3MinIOTest`, which is tagged and
  needs docker.
  """

  use O11yProxy.BackendCase,
    backend: O11yProxy.Backends.S3,
    all_operators_supported: true,
    valid_config: [
      uri: "test/fixtures/s3/logs/**/*.parquet",
      format: "parquet",
      allow_raw: true,
      mapping: %{
        "timestamp" => "ts",
        "severity" => "level",
        "body" => "message",
        "service" => "service",
        "trace_id" => "trace_id",
        "span_id" => "span_id",
        "attributes" => "attrs"
      },
      hints: %{
        "partition_key" => "ts",
        "hive_date_column" => "dt",
        "low_cardinality" => ["service", "level"]
      }
    ],
    invalid_config: [
      uri: "test/fixtures/s3/logs/**/*.parquet",
      format: "avro",
      mapping: %{}
    ],
    queries: [
      %O11yProxy.Query{
        signal: :logs,
        from: ~U[2026-09-16 00:00:00Z],
        to: ~U[2026-09-17 00:00:00Z],
        mode: :summary,
        limit: 50
      },
      %O11yProxy.Query{
        signal: :logs,
        from: ~U[2026-09-16 00:00:00Z],
        to: ~U[2026-09-17 00:00:00Z],
        mode: :sample,
        limit: 20
      },
      %O11yProxy.Query{
        signal: :logs,
        from: ~U[2026-09-16 00:00:00Z],
        to: ~U[2026-09-17 00:00:00Z],
        mode: :full,
        limit: 5
      }
    ],
    time_bound?: fn native ->
      native.sql =~ "BETWEEN ? AND ?" and match?([_, _ | _], native.params)
    end,
    limit_present?: fn native, query -> native.sql =~ "LIMIT #{query.limit}" end,
    value_isolated?: fn native, value -> not String.contains?(native.sql, to_string(value)) end
end
