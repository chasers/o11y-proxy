defmodule O11yProxy.Backends.S3MinIOTest do
  @moduledoc """
  The half of the S3 adapter that `O11yProxy.Backends.S3Test` cannot reach: the `httpfs`
  extension, `CREATE SECRET`, an S3 endpoint, gzipped NDJSON, and the CloudWatch/Firehose
  record shape that `transform` exists to flatten.

  Excluded by default (see `test/test_helper.exs`) since it needs a running MinIO and this
  sandbox has no container runtime.

  To run for real:

      docker compose -f docker/docker-compose.yml up -d
      ./docker/seed-s3.sh
      mix test --include s3_minio test/o11y_proxy/backends/s3_minio_test.exs

  The `transform` below is the same SQL `examples/cloudwatch-s3/README.md` documents. If
  one changes, change both — that doc is only trustworthy while something runs it.
  """

  use ExUnit.Case, async: true

  @moduletag :s3_minio

  alias O11yProxy.Backends.S3
  alias O11yProxy.Query
  alias O11yProxy.Query.Filter
  alias O11yProxy.Record

  @transform """
  SELECT
    to_timestamp(e.timestamp / 1000)  AS ts,
    logGroup                          AS service,
    e.message                         AS message,
    CASE
      WHEN regexp_matches(e.message, '(?i)\\b(fatal|panic)\\b')     THEN 'fatal'
      WHEN regexp_matches(e.message, '(?i)\\b(error|exception)\\b') THEN 'error'
      WHEN regexp_matches(e.message, '(?i)\\bwarn')                 THEN 'warn'
      WHEN regexp_matches(e.message, '(?i)\\bdebug\\b')             THEN 'debug'
      ELSE 'info'
    END AS level,
    map {'log_stream': logStream, 'event_id': e.id, 'account': owner} AS attrs
  FROM scan, UNNEST(logEvents) AS u(e)
  WHERE messageType = 'DATA_MESSAGE'
  """

  @config [
    uri: "s3://o11y-logs/cw/**/*.gz",
    format: "json",
    region: "us-east-1",
    access_key_id: "o11yproxy",
    secret_access_key: "o11yproxy",
    endpoint: "localhost:9010",
    url_style: "path",
    use_ssl: false,
    allow_raw: true,
    transform: @transform,
    mapping: %{
      "timestamp" => "ts",
      "severity" => "level",
      "body" => "message",
      "service" => "service",
      "attributes" => "attrs"
    },
    hints: %{
      "partition_key" => "ts",
      "hive_date_column" => "dt",
      "low_cardinality" => ["service"]
    }
  ]

  setup do
    {:ok, validated} = NimbleOptions.validate(@config, S3.config_schema())
    {:ok, state} = S3.init(Map.new(validated))
    %{state: state}
  end

  defp run(state, overrides) do
    now = DateTime.utc_now()

    query =
      Map.merge(
        %Query{
          signal: :logs,
          from: DateTime.add(now, -3600, :second),
          to: now,
          mode: :full,
          limit: 50,
          order: :desc
        },
        Map.new(overrides)
      )

    {:ok, native} = S3.compile(state, query)
    {:ok, result} = S3.execute(state, native)
    result
  end

  test "reads gzipped NDJSON out of a bucket over httpfs", %{state: state} do
    %{records: records} = run(state, [])

    assert [_, _, _, _, _] = records
    Enum.each(records, &O11yProxy.BackendCase.assert_canonical_record!/1)
  end

  test "the transform flattens logEvents into one record per event", %{state: state} do
    %{records: records} = run(state, [])

    assert Enum.sort(Enum.uniq(Enum.map(records, & &1.service))) ==
             ["/aws/lambda/checkout-api", "/aws/lambda/payments-api"]

    assert Enum.all?(records, &Map.has_key?(&1.attributes, "log_stream"))
  end

  test "the severity heuristic reads Lambda's tab-delimited message", %{state: state} do
    %{records: records} = run(state, [])

    assert Enum.sort(Enum.uniq(Enum.map(records, & &1.severity))) == [:error, :info, :warn]
    assert Enum.all?(records, &(&1.severity in Record.severities()))
  end

  test "filters push through the transform", %{state: state} do
    %{records: records} =
      run(state, filters: [%Filter{field: "body", op: :contains, value: "connection refused"}])

    assert [_, _] = records
    assert Enum.all?(records, &(&1.severity == :error))
  end

  test "the compiled query bounds the Hive partition as well as the row timestamp",
       %{state: state} do
    now = DateTime.utc_now()

    {:ok, native} =
      S3.compile(state, %Query{
        signal: :logs,
        from: DateTime.add(now, -3600, :second),
        to: now,
        mode: :full,
        limit: 5
      })

    scan = String.split(native.sql, "), src AS (") |> hd()

    assert scan =~ ~s|CAST("dt" AS DATE) BETWEEN ? AND ?|,
           "the Hive bound must sit inside the scan CTE, where it prunes objects"

    assert native.sql =~ ~s|"ts" BETWEEN ? AND ?|
  end

  test "health/1 and schema/1 reach the bucket", %{state: state} do
    assert S3.health(state) == :ok
    assert {:ok, %{fields: [_ | _]}} = S3.schema(state)
  end

  test "the session is locked down: a raw query cannot read local files", %{state: state} do
    {:ok, native} =
      S3.compile(state, %Query{
        signal: :logs,
        from: DateTime.utc_now(),
        to: DateTime.utc_now(),
        raw: "SELECT * FROM read_csv('/etc/passwd')"
      })

    assert {:error, _} = S3.execute(state, native)
  end
end
