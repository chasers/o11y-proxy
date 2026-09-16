defmodule O11yProxy.Backends.S3.MappingTest do
  @moduledoc """
  What comes back out of DuckDB, not what goes in.

  ADBC returns Arrow columns, so a result is column-oriented and its Elixir types are the
  driver's choice, not ours: a `TIMESTAMP` arrives as `NaiveDateTime`, a `MAP` as a plain
  map, an absent value as `nil`. `O11yProxy.BackendCase` only checks that a record is
  *shaped* right; these tests check it is *right*, against the known contents of
  `test/fixtures/s3/`.

  Runs in CI for the same reason `O11yProxy.Backends.S3Test` does — parquet is statically
  linked into libduckdb and the fixture is a local directory.
  """

  use ExUnit.Case, async: true

  alias O11yProxy.Backends.S3
  alias O11yProxy.Query
  alias O11yProxy.Query.Filter
  alias O11yProxy.Record

  @config [
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
      "low_cardinality" => ["service"]
    }
  ]

  # The fixture spans 2026-09-16 09:14 to 2026-09-17 08:00 across two Hive partitions.
  @from ~U[2026-09-16 00:00:00Z]
  @to ~U[2026-09-17 00:00:00Z]

  setup do
    {:ok, validated} = NimbleOptions.validate(@config, S3.config_schema())
    {:ok, state} = S3.init(Map.new(validated))
    %{state: state}
  end

  defp query(overrides) do
    Map.merge(
      %Query{signal: :logs, from: @from, to: @to, mode: :full, limit: 50, order: :asc},
      Map.new(overrides)
    )
  end

  defp run(state, overrides) do
    query = query(overrides)
    {:ok, native} = S3.compile(state, query)
    {:ok, result} = S3.execute(state, native)
    result
  end

  describe "record mapping" do
    test "timestamps come back as RFC3339 UTC strings", %{state: state} do
      %{records: [first | _]} = run(state, mode: :full)

      assert first.timestamp == "2026-09-16T09:14:02.000000Z"
      assert {:ok, _dt, 0} = DateTime.from_iso8601(first.timestamp)
    end

    test "severity text normalizes into the canonical enum", %{state: state} do
      %{records: records} = run(state, mode: :full)

      assert Enum.map(records, & &1.severity) == [:error, :warn, :info, :error, :info]
      assert Enum.all?(records, &(&1.severity in Record.severities()))
    end

    test "a MAP column becomes a plain attributes map", %{state: state} do
      %{records: [first | _]} = run(state, mode: :full)

      assert first.attributes == %{"pod" => "checkout-api-7d4f", "region" => "us-east-1"}
    end

    test "absent trace/span ids are nil, not empty strings", %{state: state} do
      %{records: records} = run(state, mode: :full)
      settlement = Enum.find(records, &(&1.body =~ "settlement batch"))

      assert settlement.trace_id == nil
      assert settlement.span_id == nil
    end

    test "present trace/span ids are carried through", %{state: state} do
      %{records: [first | _]} = run(state, mode: :full)

      assert first.trace_id == "4bf92f3577b34da6a3ce929d0e0e4736"
      assert first.span_id == "00f067aa0ba902b7"
    end

    test "`source` is left blank for O11yProxy.Sources to stamp", %{state: state} do
      %{records: records} = run(state, mode: :full)

      assert Enum.all?(records, &(&1.source == ""))
    end
  end

  describe "the time bound is real, not decorative" do
    test "rows outside the window are excluded even though their partition is scanned",
         %{state: state} do
      # 2026-09-17 08:00 sits in the dt=2026-09-17 partition, which the Hive bound does
      # include (the window's `to` is midnight on the 17th). Only the row-level bound
      # keeps it out.
      %{records: records} = run(state, mode: :full)

      refute Enum.any?(records, &(&1.body =~ "cache warm"))
      assert [_, _, _, _, _] = records
    end

    test "a narrower window returns fewer rows", %{state: state} do
      %{records: records} =
        run(state, mode: :full, from: ~U[2026-09-16 10:00:00Z], to: ~U[2026-09-16 11:00:00Z])

      assert Enum.map(records, & &1.service) == ["payments-api", "payments-api"]
    end
  end

  describe "filters" do
    test "contains matches on the body", %{state: state} do
      %{records: records} =
        run(state, filters: [%Filter{field: "body", op: :contains, value: "connection refused"}])

      assert [_, _] = records
      assert Enum.all?(records, &(&1.severity == :error))
    end

    test "in matches any of several services", %{state: state} do
      %{records: records} =
        run(state, filters: [%Filter{field: "service", op: :in, value: ["payments-api"]}])

      assert Enum.map(records, & &1.service) == ["payments-api", "payments-api"]
    end

    test "attributes.<key> reaches into the map column", %{state: state} do
      %{records: records} =
        run(state,
          filters: [%Filter{field: "attributes.pod", op: :eq, value: "payments-api-3c1e"}]
        )

      assert [_, _] = records
    end

    test "exists distinguishes null from present", %{state: state} do
      %{records: records} =
        run(state, filters: [%Filter{field: "trace_id", op: :exists, value: nil}])

      assert [_, _, _] = records
    end

    test "a hostile value matches nothing rather than executing", %{state: state} do
      %{records: records} =
        run(state,
          filters: [%Filter{field: "body", op: :contains, value: "'; DROP TABLE logs; --"}]
        )

      assert records == []
      # And the fixture is still there.
      assert %{records: [_ | _]} = run(state, mode: :full)
    end
  end

  describe "summary mode" do
    test "returns bucketed aggregate rows rather than canonical records", %{state: state} do
      %{records: rows} = run(state, mode: :summary)

      assert Enum.all?(rows, &match?(%{bucket: _, severity: _, service: _, count: _}, &1))
      refute Enum.any?(rows, &match?(%Record{}, &1))
      assert Enum.sum(Enum.map(rows, & &1.count)) == 5
    end

    test "severities in a summary row are normalized too", %{state: state} do
      %{records: rows} = run(state, mode: :summary)

      assert Enum.all?(rows, &(&1.severity in Record.severities()))
    end
  end

  describe "pagination" do
    test "a full page yields a cursor that continues where it left off", %{state: state} do
      %{records: page1, cursor: cursor} = run(state, mode: :full, limit: 2, order: :asc)

      assert [_, _] = page1

      %{records: page2} = run(state, mode: :full, limit: 2, order: :asc, cursor: cursor)

      assert [_, _] = page2
      refute Enum.any?(page2, fn r -> r.timestamp in Enum.map(page1, & &1.timestamp) end)
    end

    test "a short page yields no cursor", %{state: state} do
      result = run(state, mode: :full, limit: 50)

      refute Map.has_key?(result, :cursor)
    end

    test "a cursor is refused outside mode: full", %{state: state} do
      cursor = O11yProxy.Cursor.encode("s3", %{"ts" => "2026-09-16T09:14:02Z"})

      assert {:error, {:invalid_cursor, _}} =
               S3.compile(state, query(mode: :summary, cursor: cursor))
    end
  end

  describe "raw mode" do
    test "a single SELECT runs and returns column-keyed maps", %{state: state} do
      raw = "SELECT 1 AS one, 'two' AS two"
      {:ok, native} = S3.compile(state, query(raw: raw))

      assert {:ok, %{records: [%{"one" => 1, "two" => "two"}]}} = S3.execute(state, native)
    end

    test "a write statement is refused before it reaches DuckDB", %{state: state} do
      assert {:error, {:invalid_raw_query, _}} =
               S3.compile(state, query(raw: "COPY (SELECT 1) TO '/tmp/leak.csv'"))
    end
  end

  describe "health and schema" do
    test "health/1 answers", %{state: state} do
      assert S3.health(state) == :ok
    end

    test "schema/1 reports native types and samples low-cardinality columns", %{state: state} do
      assert {:ok, %{fields: fields}} = S3.schema(state)

      by_canonical = Map.new(fields, &{&1.canonical, &1})

      assert by_canonical["timestamp"].native == "ts"
      assert by_canonical["timestamp"].type =~ "TIMESTAMP"
      assert by_canonical["service"].cardinality == "low"
      assert "checkout-api" in by_canonical["service"].sample_values
      assert by_canonical["body"].cardinality == "unknown"
      assert by_canonical["body"].sample_values == []
    end
  end
end
