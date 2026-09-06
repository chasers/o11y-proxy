defmodule O11yProxy.Backends.ClickHouse.SQL do
  @moduledoc """
  Pure SQL-building helpers for the ClickHouse adapter — no network I/O, exhaustively
  unit-tested (`test/o11y_proxy/backends/click_house/sql_test.exs`). This is the seam
  `.plans/02-backend-behaviour.md` calls out as carrying all the injection/correctness
  risk; every value from a canonical filter goes through ClickHouse's native `{name:Type}`
  parameter binding via `Ch` — never string interpolation. Only identifiers (table,
  column names) come from validated config and are spliced directly, per
  `.plans/03-adapters.md`.
  """

  alias O11yProxy.Query

  @write_keywords ~w(INSERT DELETE UPDATE ALTER DROP TRUNCATE CREATE GRANT REVOKE
                      ATTACH DETACH RENAME EXCHANGE SYSTEM KILL OPTIMIZE SET WATCH
                      MOVE UNDROP)

  @select_fields ~w(timestamp severity body service trace_id span_id)

  @doc "Backtick-quotes an identifier (table/database/column names from trusted config)."
  @spec quote_ident(String.t()) :: String.t()
  def quote_ident(ident), do: "`" <> String.replace(ident, "`", "``") <> "`"

  @doc """
  Resolves a canonical field name to its native column, per the source's `mapping`.
  `"attributes.foo"` resolves through the `attributes` map column via ClickHouse's map
  subscript syntax.
  """
  @spec native_field(map(), String.t()) ::
          {:ok, String.t()} | {:error, {:unknown_field, String.t()}}
  def native_field(mapping, "attributes." <> key) do
    case Map.fetch(mapping, "attributes") do
      {:ok, native} -> {:ok, "#{native}[#{quote_sql_string(key)}]"}
      :error -> {:error, {:unknown_field, "attributes." <> key}}
    end
  end

  def native_field(mapping, field) do
    case Map.fetch(mapping, field) do
      {:ok, native} -> {:ok, native}
      :error -> {:error, {:unknown_field, field}}
    end
  end

  defp quote_sql_string(s), do: "'" <> String.replace(s, "'", "''") <> "'"

  @doc "The ClickHouse parameter type to declare for an Elixir filter value."
  @spec ch_type(term()) :: String.t()
  def ch_type(v) when is_integer(v), do: "Int64"
  def ch_type(v) when is_float(v), do: "Float64"
  def ch_type(v) when is_boolean(v), do: "Bool"
  def ch_type(_), do: "String"

  @doc """
  Builds a combined `WHERE`-clause fragment (without the leading `WHERE`/time bound) and
  its parameter map from canonical filters. Every filter value ends up only in the
  returned param map, keyed to a `{pN:Type}` placeholder in the clause text — never
  spliced into the clause string itself.
  """
  @spec build_where(map(), [Query.Filter.t()]) :: {:ok, {String.t(), map()}} | {:error, term()}
  def build_where(mapping, filters) do
    filters
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, {[], %{}}}, fn {filter, idx}, {:ok, {clauses, params}} ->
      case clause_for(mapping, filter, idx) do
        {:ok, {clause, nil, nil}} ->
          {:cont, {:ok, {[clause | clauses], params}}}

        {:ok, {clause, name, value}} ->
          {:cont, {:ok, {[clause | clauses], Map.put(params, name, value)}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, {clauses, params}} -> {:ok, {Enum.join(Enum.reverse(clauses), " AND "), params}}
      error -> error
    end
  end

  defp clause_for(mapping, %{field: field, op: op, value: value}, idx) do
    with {:ok, native} <- native_field(mapping, field) do
      p = :"p#{idx}"

      case op do
        :eq -> {:ok, {"#{native} = {#{p}:#{ch_type(value)}}", p, value}}
        :neq -> {:ok, {"#{native} != {#{p}:#{ch_type(value)}}", p, value}}
        :gte -> {:ok, {"#{native} >= {#{p}:#{ch_type(value)}}", p, value}}
        :lte -> {:ok, {"#{native} <= {#{p}:#{ch_type(value)}}", p, value}}
        :contains -> {:ok, {"position(#{native}, {#{p}:String}) > 0", p, to_string(value)}}
        :regex -> {:ok, {"match(#{native}, {#{p}:String})", p, to_string(value)}}
        :in -> in_clause(native, value, p)
        :exists -> {:ok, {"isNotNull(#{native})", nil, nil}}
      end
    end
  end

  defp in_clause(native, value, p) do
    list = List.wrap(value)
    elem_type = list |> List.first() |> ch_type()
    {:ok, {"#{native} IN {#{p}:Array(#{elem_type})}", p, list}}
  end

  @doc "Bucket width (seconds) targeting ~`target_buckets` buckets across the window."
  @spec bucket_seconds(DateTime.t(), DateTime.t(), pos_integer()) :: pos_integer()
  def bucket_seconds(from, to, target_buckets \\ 50) do
    window = max(DateTime.diff(to, from, :second), 1)
    window |> div(target_buckets) |> max(1) |> round_to_nice()
  end

  @nice_seconds [
    1,
    5,
    10,
    15,
    30,
    60,
    300,
    600,
    900,
    1800,
    3600,
    7200,
    14_400,
    21_600,
    43_200,
    86_400
  ]

  defp round_to_nice(raw), do: Enum.find(@nice_seconds, List.last(@nice_seconds), &(&1 >= raw))

  @doc "The `SELECT ... FROM ... WHERE <where_sql> GROUP BY ... LIMIT n` for `mode: summary`."
  @spec summary_sql(map(), String.t(), String.t(), Query.t()) :: String.t()
  def summary_sql(mapping, table_path, where_sql, query) do
    bucket = bucket_seconds(query.from, query.to)
    {:ok, severity} = native_field(mapping, "severity")
    {:ok, service} = native_field(mapping, "service")
    {:ok, ts} = native_field(mapping, "timestamp")

    "SELECT toStartOfInterval(#{ts}, INTERVAL #{bucket} SECOND) AS bucket, " <>
      "#{severity} AS severity, #{service} AS service, count() AS count " <>
      "FROM #{table_path} WHERE #{where_sql} " <>
      "GROUP BY bucket, severity, service ORDER BY bucket #{order(query)} LIMIT #{query.limit}"
  end

  @doc """
  The record-projection SQL for `mode: sample` — representative rows spread across the
  window (`ORDER BY rand()`), not just the most recent N.
  """
  @spec sample_sql(map(), String.t(), String.t(), Query.t()) :: String.t()
  def sample_sql(mapping, table_path, where_sql, query) do
    "SELECT #{select_columns(mapping)} FROM #{table_path} WHERE #{where_sql} " <>
      "ORDER BY rand() LIMIT #{query.limit}"
  end

  @doc "The record-projection SQL for `mode: full` — most recent/oldest N, in order."
  @spec full_sql(map(), String.t(), String.t(), Query.t()) :: String.t()
  def full_sql(mapping, table_path, where_sql, query) do
    {:ok, ts} = native_field(mapping, "timestamp")

    "SELECT #{select_columns(mapping)} FROM #{table_path} WHERE #{where_sql} " <>
      "ORDER BY #{ts} #{order(query)} LIMIT #{query.limit}"
  end

  defp order(%{order: :asc}), do: "ASC"
  defp order(_), do: "DESC"

  @doc """
  Keyset-pagination WHERE fragment for `mode: full`'s cursor continuation — single-field
  on `timestamp` (`ts < {cursor:...}` for `DESC`, `>` for `ASC`), per the Phase 5 cursor
  design in `.plans/03-adapters.md`. A `nil` cursor yields no extra clause/param. Decode
  failures (garbage, or a cursor minted by a different backend) surface as
  `{:invalid_cursor, cursor}` rather than silently ignored or spliced raw.

  Known limitation, documented rather than hidden: this is a single-column key, so ties
  within the same millisecond at the page boundary may repeat or skip a row — the same
  spirit as this codebase's other documented per-vendor dialect limits.
  """
  @spec cursor_bound(map(), String.t() | nil, :asc | :desc) ::
          {:ok, {String.t(), DateTime.t() | nil}} | {:error, {:invalid_cursor, term()}}
  def cursor_bound(_mapping, nil, _order), do: {:ok, {"", nil}}

  def cursor_bound(mapping, cursor, order) do
    with {:ok, %{"ts" => ts_str}} <- O11yProxy.Cursor.decode(cursor, "clickhouse"),
         {:ok, ts, _offset} <- DateTime.from_iso8601(ts_str),
         {:ok, native} <- native_field(mapping, "timestamp") do
      op = if order == :asc, do: ">", else: "<"
      {:ok, {"#{native} #{op} {cursor:DateTime64(3)}", ts}}
    else
      _ -> {:error, {:invalid_cursor, cursor}}
    end
  end

  defp select_columns(mapping) do
    projected =
      Enum.map_join(@select_fields, ", ", fn f ->
        {:ok, native} = native_field(mapping, f)
        "#{native} AS #{f}"
      end)

    projected <> ", #{attributes_column(mapping)} AS attributes"
  end

  defp attributes_column(mapping), do: Map.get(mapping, "attributes", "map()")

  @doc """
  Guardrail for the `raw` escape hatch: only a single `SELECT` (optionally with a leading
  `WITH`/CTE) is allowed. Defense in depth — the real boundary is the read-only ClickHouse
  user — but a client typo or a prompt-injected write statement should fail here first.
  """
  @spec validate_single_select(String.t()) :: :ok | {:error, {:invalid_raw_query, String.t()}}
  def validate_single_select(sql) when is_binary(sql) do
    trimmed = String.trim(sql)
    upcased = String.upcase(trimmed)

    cond do
      trimmed == "" ->
        {:error, {:invalid_raw_query, "empty query"}}

      not (String.starts_with?(upcased, "SELECT") or String.starts_with?(upcased, "WITH")) ->
        {:error,
         {:invalid_raw_query,
          "only a single SELECT (optionally with a WITH/CTE prefix) is allowed"}}

      has_multiple_statements?(trimmed) ->
        {:error, {:invalid_raw_query, "only a single statement is allowed"}}

      contains_write_keyword?(upcased) ->
        {:error, {:invalid_raw_query, "write/DDL keywords are not allowed in a raw query"}}

      true ->
        :ok
    end
  end

  defp has_multiple_statements?(sql) do
    sql |> String.trim_trailing() |> String.trim_trailing(";") |> String.contains?(";")
  end

  defp contains_write_keyword?(upcased) do
    Enum.any?(@write_keywords, &Regex.match?(~r/\b#{&1}\b/, upcased))
  end
end
