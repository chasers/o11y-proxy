defmodule O11yProxy.Backends.S3.SQL do
  @moduledoc """
  Pure DuckDB SQL-building helpers for the S3 adapter — no network I/O, exhaustively
  unit-tested (`test/o11y_proxy/backends/s3/sql_test.exs`). Mirrors
  `O11yProxy.Backends.ClickHouse.SQL`'s split for the same reason: this is the seam that
  carries injection/correctness risk, so it stays pure and gets exhaustive tests with no
  network mocking.

  Every value from a canonical filter leaves here in the returned **ordered params list**
  and appears in the SQL text only as a positional `?`. DuckDB binds those through ADBC's
  Arrow parameter path, so a hostile filter value is never parsed as SQL. Identifiers
  (the URI, column names, the `transform` SELECT) come from validated config and are
  spliced — the same boundary ClickHouse draws.

  Every compiled query is a two-CTE sandwich:

      WITH scan AS (SELECT * FROM read_json('s3://...', ...) WHERE <hive bound>),
           src  AS (<transform, or SELECT * FROM scan>)
      SELECT <projection> FROM src WHERE <time bound> AND <filters> ORDER BY ... LIMIT n

  `scan` is the raw object scan and is where the **Hive partition bound** goes. It lives
  inside the CTE deliberately: pushed down from the outer `WHERE` it might not survive an
  `UNNEST` in `transform`, and partition pruning is the entire cost story on object
  storage — an unpruned query re-reads the bucket and bills for every GET.

  `src` is `transform` if the source sets one, so a nested shape (CloudWatch's `logEvents`
  array) can be flattened into columns `mapping` can name.
  """

  alias O11yProxy.Backends.ClickHouse.SQL, as: CHSQL
  alias O11yProxy.Cursor
  alias O11yProxy.Query
  alias O11yProxy.SQLGuard

  # DuckDB's write and side-effect verbs. Wider than ClickHouse's list because DuckDB can
  # reach the filesystem and the extension repository from inside a query: COPY writes
  # files, INSTALL/LOAD pull code, ATTACH mounts another database, and SET would undo the
  # session guardrails if `lock_configuration` ever failed to apply.
  @write_keywords ~w(INSERT DELETE UPDATE ALTER DROP TRUNCATE CREATE GRANT REVOKE
                      ATTACH DETACH RENAME COPY EXPORT IMPORT INSTALL LOAD PRAGMA CALL
                      SET RESET VACUUM ANALYZE CHECKPOINT UPDATE_EXTENSIONS)

  @select_fields ~w(timestamp severity body service trace_id span_id)

  @doc "The DuckDB write/DDL keywords rejected in a raw query. Exposed for the tests."
  @spec write_keywords() :: [String.t()]
  def write_keywords, do: @write_keywords

  @doc """
  Guardrail for the `raw` escape hatch: a single `SELECT`, no DuckDB write verbs.

  Layered under the session guardrails `O11yProxy.Backends.S3` sets up
  (`disabled_filesystems`, `lock_configuration`), never instead of them.
  """
  @spec validate_single_select(String.t()) :: :ok | {:error, {:invalid_raw_query, String.t()}}
  def validate_single_select(sql) when is_binary(sql),
    do: SQLGuard.validate_single_select(sql, @write_keywords)

  @doc """
  Double-quotes an identifier (column names from validated config).
  """
  @spec quote_ident(String.t()) :: String.t()
  def quote_ident(ident), do: "\"" <> String.replace(ident, "\"", "\"\"") <> "\""

  @doc "Single-quotes a string literal. Only ever applied to config-sourced values."
  @spec quote_literal(String.t()) :: String.t()
  def quote_literal(value), do: "'" <> String.replace(to_string(value), "'", "''") <> "'"

  @doc """
  Resolves a canonical field name to an expression over `src`, per the source's `mapping`.

  `"attributes.foo"` resolves through the mapped attributes column. `access` picks the
  subscript dialect: `:map` for DuckDB `MAP`/`STRUCT` columns (`attrs['foo']`), `:json`
  for a JSON or VARCHAR column holding JSON (`attrs->>'foo'`). The key is a caller-supplied
  string, so it is quoted as a literal rather than spliced bare.
  """
  @spec native_field(map(), String.t(), :map | :json) ::
          {:ok, String.t()} | {:error, {:unknown_field, String.t()}}
  def native_field(mapping, "attributes." <> key, access) do
    case Map.fetch(mapping, "attributes") do
      {:ok, native} -> {:ok, attribute_expr(native, key, access)}
      :error -> {:error, {:unknown_field, "attributes." <> key}}
    end
  end

  def native_field(mapping, field, _access) do
    case Map.fetch(mapping, field) do
      {:ok, native} -> {:ok, quote_ident(native)}
      :error -> {:error, {:unknown_field, field}}
    end
  end

  defp attribute_expr(native, key, :json),
    do: "#{quote_ident(native)}->>#{quote_literal(key)}"

  defp attribute_expr(native, key, _map),
    do: "#{quote_ident(native)}[#{quote_literal(key)}]"

  @doc """
  Builds the `scan` CTE: the object scan plus, when the source declares a Hive date
  column, a bound on it derived from the query window.

  Returns `{sql, params}`. The bound is expressed as `CAST(col AS DATE) BETWEEN ? AND ?`
  so it works whether DuckDB inferred the partition column as `DATE` (it usually does for
  `dt=2026-09-16`) or left it `VARCHAR`.
  """
  @spec scan_cte(map(), Query.t()) :: {String.t(), [term()]}
  def scan_cte(state, query) do
    {bound, params} = hive_bound(state, query)
    where = if bound == "", do: "", else: " WHERE #{bound}"
    {"scan AS (SELECT * FROM #{read_function(state)}#{where})", params}
  end

  defp hive_bound(%{hive_date_column: nil}, _query), do: {"", []}

  defp hive_bound(%{hive_date_column: column}, query) do
    {"CAST(#{quote_ident(column)} AS DATE) BETWEEN ? AND ?",
     [DateTime.to_date(query.from), DateTime.to_date(query.to)]}
  end

  @doc """
  The DuckDB table function for the source's `format` and `uri`, with its read options.

  `union_by_name` is on for JSON because an object storage prefix accumulates shapes over
  time — a field added last Tuesday must not make every older file unreadable.
  """
  @spec read_function(map()) :: String.t()
  def read_function(state) do
    {fun, defaults} = reader(state.format)

    options =
      defaults
      |> Map.merge(%{"hive_partitioning" => state.hive_partitioning})
      |> Map.merge(state.read_options)
      |> Enum.sort()
      |> Enum.map_join(", ", fn {k, v} -> "#{k} = #{option_literal(v)}" end)

    "#{fun}(#{quote_literal(state.uri)}, #{options})"
  end

  defp reader("parquet"), do: {"read_parquet", %{"union_by_name" => true}}
  defp reader("csv"), do: {"read_csv", %{"union_by_name" => true, "header" => true}}

  defp reader(_json),
    do: {"read_json", %{"union_by_name" => true, "format" => "newline_delimited"}}

  defp option_literal(v) when is_boolean(v), do: to_string(v)
  defp option_literal(v) when is_number(v), do: to_string(v)
  defp option_literal(v), do: quote_literal(v)

  @doc """
  The `src` CTE: the source's `transform` SELECT, or a pass-through over `scan`.

  A configured `transform` is validated as a single `SELECT` first — it is config, not
  request input, but a typo that reads `COPY` should fail at boot rather than at 3am.
  """
  @spec src_cte(map()) :: {:ok, String.t()} | {:error, term()}
  def src_cte(%{transform: ""}), do: {:ok, "src AS (SELECT * FROM scan)"}

  def src_cte(%{transform: transform}) do
    with :ok <- validate_single_select(transform) do
      {:ok, "src AS (#{String.trim_trailing(String.trim(transform), ";")})"}
    end
  end

  @doc """
  Builds a `WHERE`-clause fragment (without the leading `WHERE`/time bound) and its
  ordered parameter list from canonical filters. Every filter value ends up only in the
  returned list, positionally matched to a `?` in the clause text.
  """
  @spec build_where(map(), [Query.Filter.t()], :map | :json) ::
          {:ok, {String.t(), [term()]}} | {:error, term()}
  def build_where(mapping, filters, access) do
    filters
    |> Enum.reduce_while({:ok, {[], []}}, fn filter, {:ok, {clauses, params}} ->
      case clause_for(mapping, filter, access) do
        {:ok, {clause, values}} -> {:cont, {:ok, {[clause | clauses], [values | params]}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, {clauses, params}} ->
        # `params` is a reversed list of per-filter value lists. `Enum.concat/1` flattens
        # exactly one level, which matters: an `in` filter's values are themselves a list,
        # and `List.flatten/1` would happily flatten a list-valued filter into its elements
        # and silently shift every placeholder after it.
        {:ok,
         {Enum.join(Enum.reverse(clauses), " AND "), params |> Enum.reverse() |> Enum.concat()}}

      error ->
        error
    end
  end

  defp clause_for(mapping, %{field: field, op: op, value: value}, access) do
    with {:ok, native} <- native_field(mapping, field, access) do
      case op do
        :eq -> {:ok, {"#{native} = ?", [value]}}
        :neq -> {:ok, {"#{native} != ?", [value]}}
        :gte -> {:ok, {"#{native} >= ?", [value]}}
        :lte -> {:ok, {"#{native} <= ?", [value]}}
        :contains -> {:ok, {"contains(CAST(#{native} AS VARCHAR), ?)", [to_string(value)]}}
        :regex -> {:ok, {"regexp_matches(CAST(#{native} AS VARCHAR), ?)", [to_string(value)]}}
        :in -> in_clause(native, value)
        :exists -> {:ok, {"#{native} IS NOT NULL", []}}
      end
    end
  end

  # DuckDB has no array-parameter binding through ADBC, so an `in` filter expands to one
  # placeholder per element rather than a single bound list. The values still never reach
  # the SQL text.
  defp in_clause(_native, []), do: {:error, {:invalid_query, "`in` filter needs a value"}}

  defp in_clause(native, value) do
    list = List.wrap(value)
    placeholders = Enum.map_join(list, ", ", fn _ -> "?" end)
    {:ok, {"#{native} IN (#{placeholders})", list}}
  end

  @doc "Bucket width (seconds) targeting ~50 buckets across the window."
  @spec bucket_seconds(DateTime.t(), DateTime.t()) :: pos_integer()
  def bucket_seconds(from, to), do: CHSQL.bucket_seconds(from, to)

  @doc "The `GROUP BY` projection for `mode: summary`."
  @spec summary_sql(map(), String.t(), String.t(), Query.t()) :: String.t()
  def summary_sql(state, ctes, where_sql, query) do
    bucket = bucket_seconds(query.from, query.to)
    {:ok, severity} = native_field(state.mapping, "severity", state.attribute_access)
    {:ok, service} = native_field(state.mapping, "service", state.attribute_access)
    {:ok, ts} = native_field(state.mapping, "timestamp", state.attribute_access)

    "WITH #{ctes} " <>
      "SELECT time_bucket(INTERVAL '#{bucket} seconds', #{ts}) AS bucket, " <>
      "#{severity} AS severity, #{service} AS service, count(*) AS count " <>
      "FROM src WHERE #{where_sql} " <>
      "GROUP BY bucket, severity, service ORDER BY bucket #{order(query)} LIMIT #{query.limit}"
  end

  @doc """
  The record projection for `mode: sample` — rows spread across the window
  (`ORDER BY random()`), not just the most recent N.
  """
  @spec sample_sql(map(), String.t(), String.t(), Query.t()) :: String.t()
  def sample_sql(state, ctes, where_sql, query) do
    "WITH #{ctes} SELECT #{select_columns(state)} FROM src WHERE #{where_sql} " <>
      "ORDER BY random() LIMIT #{query.limit}"
  end

  @doc "The record projection for `mode: full` — most recent/oldest N, in order."
  @spec full_sql(map(), String.t(), String.t(), Query.t()) :: String.t()
  def full_sql(state, ctes, where_sql, query) do
    {:ok, ts} = native_field(state.mapping, "timestamp", state.attribute_access)

    "WITH #{ctes} SELECT #{select_columns(state)} FROM src WHERE #{where_sql} " <>
      "ORDER BY #{ts} #{order(query)} LIMIT #{query.limit}"
  end

  defp order(%{order: :asc}), do: "ASC"
  defp order(_), do: "DESC"

  @doc """
  Keyset-pagination `WHERE` fragment for `mode: full`'s cursor continuation — single-field
  on `timestamp` (`ts < ?` for `DESC`, `>` for `ASC`). A `nil` cursor yields no clause and
  no param. Decode failures (garbage, or a cursor minted by another backend) surface as
  `{:invalid_cursor, cursor}` rather than being ignored or spliced raw.

  Same documented limitation as the ClickHouse adapter's: a single-column key means ties
  inside one microsecond at a page boundary may repeat or skip a row.
  """
  @spec cursor_bound(map(), String.t() | nil, :asc | :desc, :map | :json) ::
          {:ok, {String.t(), [NaiveDateTime.t()]}} | {:error, {:invalid_cursor, term()}}
  def cursor_bound(_mapping, nil, _order, _access), do: {:ok, {"", []}}

  def cursor_bound(mapping, cursor, order, access) do
    with {:ok, %{"ts" => ts_str}} <- Cursor.decode(cursor, "s3"),
         {:ok, ts, _offset} <- DateTime.from_iso8601(ts_str),
         {:ok, native} <- native_field(mapping, "timestamp", access) do
      op = if order == :asc, do: ">", else: "<"
      {:ok, {"#{native} #{op} ?", [DateTime.to_naive(ts)]}}
    else
      _ -> {:error, {:invalid_cursor, cursor}}
    end
  end

  defp select_columns(state) do
    projected =
      Enum.map_join(@select_fields, ", ", fn field ->
        case native_field(state.mapping, field, state.attribute_access) do
          {:ok, native} -> "#{native} AS #{field}"
          # trace_id/span_id are genuinely absent from most log shapes. Project a typed
          # NULL rather than failing the query, so the canonical record still validates.
          {:error, _} -> "CAST(NULL AS VARCHAR) AS #{field}"
        end
      end)

    projected <> ", #{attributes_column(state)} AS attributes"
  end

  defp attributes_column(state) do
    case Map.fetch(state.mapping, "attributes") do
      {:ok, native} -> quote_ident(native)
      :error -> "MAP {}"
    end
  end
end
