defmodule O11yProxy.Backends.S3.SQLTest do
  @moduledoc """
  Exhaustive tests for the S3 adapter's pure compile seam. No network, no DuckDB — this is
  the layer that decides whether a filter value can become SQL, and it is testable without
  either.
  """

  use ExUnit.Case, async: true

  alias O11yProxy.Backends.S3.SQL
  alias O11yProxy.Cursor
  alias O11yProxy.Query
  alias O11yProxy.Query.Filter

  @mapping %{
    "timestamp" => "ts",
    "severity" => "level",
    "body" => "message",
    "service" => "service",
    "attributes" => "attrs"
  }

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        uri: "s3://acme-logs/cw/**/*.gz",
        format: "json",
        hive_partitioning: true,
        read_options: %{},
        transform: "",
        mapping: @mapping,
        attribute_access: :map,
        hive_date_column: nil
      },
      overrides
    )
  end

  defp query(overrides \\ %{}) do
    from = ~U[2026-09-16 00:00:00Z]

    Map.merge(
      %Query{
        signal: :logs,
        from: from,
        to: ~U[2026-09-16 01:00:00Z],
        mode: :full,
        limit: 50,
        order: :desc
      },
      overrides
    )
  end

  describe "read_function/1" do
    test "json reads newline-delimited objects and unions schemas across files" do
      sql = SQL.read_function(state())

      assert sql =~ "read_json('s3://acme-logs/cw/**/*.gz'"
      assert sql =~ "format = 'newline_delimited'"
      assert sql =~ "union_by_name = true"
      assert sql =~ "hive_partitioning = true"
    end

    test "parquet and csv use their own readers" do
      assert SQL.read_function(state(%{format: "parquet"})) =~ "read_parquet("
      assert SQL.read_function(state(%{format: "csv"})) =~ "read_csv("
      assert SQL.read_function(state(%{format: "csv"})) =~ "header = true"
    end

    test "hive_partitioning: false is honoured" do
      assert SQL.read_function(state(%{hive_partitioning: false})) =~ "hive_partitioning = false"
    end

    test "read_options override the defaults rather than being appended twice" do
      sql =
        SQL.read_function(
          state(%{read_options: %{"union_by_name" => false, "maximum_depth" => 3}})
        )

      assert sql =~ "union_by_name = false"
      refute sql =~ "union_by_name = true"
      assert sql =~ "maximum_depth = 3"
    end

    test "a uri containing a quote cannot end the literal early" do
      sql = SQL.read_function(state(%{uri: "s3://b/a'); DROP TABLE t; --"}))

      assert sql =~ "'s3://b/a''); DROP TABLE t; --'"
    end
  end

  describe "scan_cte/2" do
    test "without a hive date column there is no scan-level filter and no params" do
      {sql, params} = SQL.scan_cte(state(), query())

      assert params == []
      refute sql =~ "WHERE"
    end

    test "with a hive date column the bound lands inside the scan CTE, as params" do
      {sql, params} = SQL.scan_cte(state(%{hive_date_column: "dt"}), query())

      assert sql =~ ~s|WHERE CAST("dt" AS DATE) BETWEEN ? AND ?|
      assert params == [~D[2026-09-16], ~D[2026-09-16]]
    end

    test "the hive bound spans every date the window touches" do
      {_sql, params} =
        SQL.scan_cte(
          state(%{hive_date_column: "dt"}),
          query(%{from: ~U[2026-09-14 22:00:00Z], to: ~U[2026-09-16 03:00:00Z]})
        )

      assert params == [~D[2026-09-14], ~D[2026-09-16]]
    end
  end

  describe "src_cte/1" do
    test "defaults to a pass-through over scan" do
      assert SQL.src_cte(state()) == {:ok, "src AS (SELECT * FROM scan)"}
    end

    test "wraps a configured transform, trimming a trailing semicolon" do
      transform = "SELECT a FROM scan, UNNEST(logEvents) AS u(e);"

      assert {:ok, sql} = SQL.src_cte(state(%{transform: transform}))
      assert sql == "src AS (SELECT a FROM scan, UNNEST(logEvents) AS u(e))"
    end

    test "rejects a transform that is not a single SELECT" do
      assert {:error, {:invalid_raw_query, _}} =
               SQL.src_cte(state(%{transform: "COPY scan TO 's3://elsewhere/x.parquet'"}))

      assert {:error, {:invalid_raw_query, _}} =
               SQL.src_cte(state(%{transform: "SELECT 1; SELECT 2"}))
    end

    test "a column merely containing a keyword is not a write statement" do
      assert {:ok, _} = SQL.src_cte(state(%{transform: "SELECT offset, dropped FROM scan"}))
    end
  end

  describe "native_field/3" do
    test "resolves a mapped canonical field to a quoted column" do
      assert SQL.native_field(@mapping, "body", :map) == {:ok, ~s|"message"|}
    end

    test "resolves attributes.<key> through the map column" do
      assert SQL.native_field(@mapping, "attributes.pod", :map) == {:ok, ~s|"attrs"['pod']|}
    end

    test "resolves attributes.<key> through a JSON column when configured" do
      assert SQL.native_field(@mapping, "attributes.pod", :json) == {:ok, ~s|"attrs"->>'pod'|}
    end

    test "an attribute key cannot end the literal early" do
      assert {:ok, expr} = SQL.native_field(@mapping, "attributes.a'] OR 1=1 --", :map)
      assert expr == ~s|"attrs"['a''] OR 1=1 --']|
    end

    test "an unmapped field is an error, not a guess" do
      assert SQL.native_field(@mapping, "nope", :map) == {:error, {:unknown_field, "nope"}}
    end

    test "attributes.<key> is an error when the source maps no attributes column" do
      assert SQL.native_field(%{}, "attributes.x", :map) ==
               {:error, {:unknown_field, "attributes.x"}}
    end
  end

  describe "build_where/3" do
    for {op, expected} <- [
          eq: ~s|"message" = ?|,
          neq: ~s|"message" != ?|,
          gte: ~s|"message" >= ?|,
          lte: ~s|"message" <= ?|,
          contains: ~s|contains(CAST("message" AS VARCHAR), ?)|,
          regex: ~s|regexp_matches(CAST("message" AS VARCHAR), ?)|
        ] do
      test "#{op} compiles to a single placeholder" do
        filter = %Filter{field: "body", op: unquote(op), value: "boom"}

        assert {:ok, {sql, params}} = SQL.build_where(@mapping, [filter], :map)
        assert sql == unquote(expected)
        assert params == ["boom"]
      end
    end

    test "exists needs no parameter at all" do
      filter = %Filter{field: "body", op: :exists, value: nil}

      assert SQL.build_where(@mapping, [filter], :map) == {:ok, {~s|"message" IS NOT NULL|, []}}
    end

    test "in expands to one placeholder per element" do
      filter = %Filter{field: "service", op: :in, value: ["a", "b", "c"]}

      assert {:ok, {sql, params}} = SQL.build_where(@mapping, [filter], :map)
      assert sql == ~s|"service" IN (?, ?, ?)|
      assert params == ["a", "b", "c"]
    end

    test "an empty in list is rejected rather than compiling to `IN ()`" do
      filter = %Filter{field: "service", op: :in, value: []}

      assert {:error, {:invalid_query, _}} = SQL.build_where(@mapping, [filter], :map)
    end

    test "multiple filters keep clause order and parameter order in step" do
      filters = [
        %Filter{field: "service", op: :eq, value: "checkout-api"},
        %Filter{field: "service", op: :in, value: ["a", "b"]},
        %Filter{field: "body", op: :contains, value: "refused"}
      ]

      assert {:ok, {sql, params}} = SQL.build_where(@mapping, filters, :map)

      assert sql ==
               ~s|"service" = ? AND "service" IN (?, ?) AND contains(CAST("message" AS VARCHAR), ?)|

      assert params == ["checkout-api", "a", "b", "refused"]
    end

    test "a filter on an unmapped field fails the whole compile" do
      filters = [%Filter{field: "nope", op: :eq, value: 1}]

      assert {:error, {:unknown_field, "nope"}} = SQL.build_where(@mapping, filters, :map)
    end

    test "no filter value ever reaches the SQL text" do
      hostile = O11yProxy.BackendCase.default_hostile_values()

      for value <- hostile, op <- [:eq, :neq, :contains, :regex, :in] do
        filter = %Filter{field: "body", op: op, value: value}

        assert {:ok, {sql, params}} = SQL.build_where(@mapping, [filter], :map)
        refute String.contains?(sql, to_string(value))
        assert params == [if(op in [:contains, :regex], do: to_string(value), else: value)]
      end
    end
  end

  describe "cursor_bound/4" do
    test "a nil cursor adds no clause and no param" do
      assert SQL.cursor_bound(@mapping, nil, :desc, :map) == {:ok, {"", []}}
    end

    test "desc pages backwards, asc forwards" do
      cursor = Cursor.encode("s3", %{"ts" => "2026-09-16T00:30:00Z"})

      assert {:ok, {~s|"ts" < ?|, [ts]}} = SQL.cursor_bound(@mapping, cursor, :desc, :map)
      assert ts == ~N[2026-09-16 00:30:00Z]
      assert {:ok, {~s|"ts" > ?|, _}} = SQL.cursor_bound(@mapping, cursor, :asc, :map)
    end

    test "a cursor minted by another backend is rejected, not spliced" do
      foreign = Cursor.encode("clickhouse", %{"ts" => "2026-09-16T00:30:00Z"})

      assert {:error, {:invalid_cursor, ^foreign}} =
               SQL.cursor_bound(@mapping, foreign, :desc, :map)
    end

    test "garbage is rejected" do
      assert {:error, {:invalid_cursor, "not-a-cursor"}} =
               SQL.cursor_bound(@mapping, "not-a-cursor", :desc, :map)
    end
  end

  describe "projections" do
    @ctes "scan AS (SELECT * FROM read_json('x')), src AS (SELECT * FROM scan)"

    test "summary buckets, groups and limits" do
      sql = SQL.summary_sql(state(), @ctes, ~s|"ts" BETWEEN ? AND ?|, query(%{mode: :summary}))

      assert sql =~ "time_bucket(INTERVAL '"
      assert sql =~ ~s|"level" AS severity|
      assert sql =~ "count(*) AS count"
      assert sql =~ "GROUP BY bucket, severity, service"
      assert sql =~ "LIMIT 50"
    end

    test "sample spreads across the window rather than taking the most recent N" do
      sql = SQL.sample_sql(state(), @ctes, "1=1", query(%{mode: :sample, limit: 20}))

      assert sql =~ "ORDER BY random()"
      assert sql =~ "LIMIT 20"
    end

    test "full orders by the timestamp column, honouring order" do
      assert SQL.full_sql(state(), @ctes, "1=1", query()) =~ ~s|ORDER BY "ts" DESC|
      assert SQL.full_sql(state(), @ctes, "1=1", query(%{order: :asc})) =~ ~s|ORDER BY "ts" ASC|
    end

    test "a record projection always emits all seven canonical columns" do
      sql = SQL.full_sql(state(), @ctes, "1=1", query())

      for field <- ~w(timestamp severity body service trace_id span_id attributes) do
        assert sql =~ "AS #{field}"
      end
    end

    test "fields the source does not map project a typed NULL rather than failing" do
      sql = SQL.full_sql(state(), @ctes, "1=1", query())

      assert sql =~ "CAST(NULL AS VARCHAR) AS trace_id"
      assert sql =~ "CAST(NULL AS VARCHAR) AS span_id"
    end

    test "a source with no attributes column projects an empty map" do
      bare = state(%{mapping: Map.delete(@mapping, "attributes")})

      assert SQL.full_sql(bare, @ctes, "1=1", query()) =~ "MAP {} AS attributes"
    end
  end

  describe "validate_single_select/1" do
    test "accepts a SELECT and a CTE" do
      assert SQL.validate_single_select("SELECT 1") == :ok
      assert SQL.validate_single_select("WITH a AS (SELECT 1) SELECT * FROM a") == :ok
    end

    test "rejects DuckDB's own filesystem and extension verbs" do
      for sql <- [
            "COPY (SELECT 1) TO '/tmp/x.csv'",
            "SELECT 1; INSTALL httpfs",
            "SELECT 1; LOAD httpfs",
            "ATTACH 'other.db'",
            "PRAGMA database_list",
            "SET disabled_filesystems = ''"
          ] do
        assert {:error, {:invalid_raw_query, _}} = SQL.validate_single_select(sql),
               "expected #{sql} to be rejected"
      end
    end

    test "rejects an empty query" do
      assert {:error, {:invalid_raw_query, "empty query"}} = SQL.validate_single_select("   ")
    end

    test "the DuckDB keyword list is strictly wider than ClickHouse's shared verbs" do
      assert "COPY" in SQL.write_keywords()
      assert "INSTALL" in SQL.write_keywords()
      assert "INSERT" in SQL.write_keywords()
    end
  end
end
