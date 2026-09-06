defmodule O11yProxy.Backends.ClickHouse do
  @moduledoc """
  Logs and traces adapter over ClickHouse's HTTP interface, via the `ch` client. Built
  first per `.plans/03-adapters.md`: user-defined tables make it the hardest case for
  the `O11yProxy.Backend` abstraction — the same adapter serves an OTel-standard
  `otel_logs` table and a bespoke one, differing only in `mapping`, and a second source
  over `otel_traces` (same adapter, different config) is exactly that in practice.

  Guardrails, layered (see "Security" in `.plans/04-cross-cutting.md`):
    * a dedicated read-only ClickHouse user is the real boundary — configure it at the
      database, this adapter cannot enforce it
    * every query carries `readonly=1` plus `max_execution_time`/`max_result_rows`/
      `max_bytes_to_read` settings
    * every compiled query carries a bound on `hints.partition_key` (`compile/2` always
      injects it — see `O11yProxy.Backends.ClickHouse.SQL`)
    * the `raw` escape hatch is validated as a single `SELECT` and gated on `allow_raw`
  """

  @behaviour O11yProxy.Backend

  alias O11yProxy.Backends.ClickHouse.SQL
  alias O11yProxy.Record

  @operators [:eq, :neq, :gte, :lte, :contains, :regex, :in, :exists]

  @impl true
  def config_schema do
    [
      url: [type: :string, required: true, doc: "e.g. \"http://localhost:8123\""],
      user: [type: :string, required: true],
      password: [type: :string, required: true],
      database: [type: :string, required: true],
      table: [type: :string, required: true],
      allow_raw: [type: :boolean, default: false],
      mapping: [
        type: {:map, :string, :string},
        required: true,
        doc: "canonical field -> native column, e.g. %{\"timestamp\" => \"Timestamp\"}"
      ],
      hints: [
        type: {:map, :string, :any},
        default: %{},
        doc:
          "\"partition_key\" (native column, always bounded) and \"low_cardinality\" ([native columns])"
      ],
      pool_size: [type: :pos_integer, default: 5],
      timeout_ms: [type: :pos_integer, default: 30_000],
      max_execution_time_s: [type: :pos_integer, default: 25],
      max_result_rows: [type: :pos_integer, default: 100_000],
      max_bytes_to_read: [type: :pos_integer, default: 1_000_000_000_000]
    ]
  end

  @impl true
  def init(config) do
    uri = URI.parse(config.url)
    pool_name = Module.concat(__MODULE__.Pool, "P#{:erlang.unique_integer([:positive])}")

    with {:ok, _pid} <-
           Ch.start_link(
             name: pool_name,
             scheme: uri.scheme || "http",
             hostname: uri.host || "localhost",
             port: uri.port || 8123,
             database: config.database,
             username: config.user,
             password: config.password,
             pool_size: config.pool_size
           ) do
      partition_key =
        Map.get(config.hints, "partition_key") || Map.fetch!(config.mapping, "timestamp")

      {:ok,
       %{
         conn: pool_name,
         database: config.database,
         table: config.table,
         table_path: "#{SQL.quote_ident(config.database)}.#{SQL.quote_ident(config.table)}",
         allow_raw: config.allow_raw,
         mapping: config.mapping,
         partition_key: partition_key,
         low_cardinality: Map.get(config.hints, "low_cardinality", []),
         timeout_ms: config.timeout_ms,
         settings: [
           readonly: 1,
           max_execution_time: config.max_execution_time_s,
           max_result_rows: config.max_result_rows,
           result_overflow_mode: "break",
           max_bytes_to_read: config.max_bytes_to_read
         ]
       }}
    end
  end

  @impl true
  def capabilities(state) do
    %{
      signals: [:logs, :traces],
      operators: @operators,
      modes: [:summary, :sample, :full],
      raw: state.allow_raw,
      max_window_ms: :infinity
    }
  end

  @impl true
  def schema(state) do
    sql =
      "SELECT name, type FROM system.columns WHERE database = {database:String} AND table = {table:String}"

    params = %{database: state.database, table: state.table}

    case run(state, sql, params) do
      {:ok, %Ch.Result{rows: rows}} ->
        native_types = Map.new(rows, fn [name, type] -> {name, type} end)

        fields =
          for {canonical, native} <- state.mapping do
            %{
              canonical: canonical,
              native: native,
              type: Map.get(native_types, native, "unknown"),
              filterable: true,
              cardinality: if(native in state.low_cardinality, do: "low", else: "unknown"),
              sample_values: sample_values(state, native)
            }
          end

        {:ok, %{name: state.table, fields: fields}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sample_values(state, native) do
    if native in state.low_cardinality do
      sql = "SELECT DISTINCT #{native} FROM #{state.table_path} LIMIT 20"

      case run(state, sql, %{}) do
        {:ok, %Ch.Result{rows: rows}} -> Enum.map(rows, fn [v] -> v end)
        {:error, _} -> []
      end
    else
      []
    end
  end

  @impl true
  def compile(state, query) do
    if query.raw do
      compile_raw(state, query)
    else
      compile_structured(state, query)
    end
  end

  defp compile_raw(state, query) do
    cond do
      not state.allow_raw ->
        {:error, {:raw_not_allowed, "this source does not set allow_raw: true"}}

      true ->
        case SQL.validate_single_select(query.raw) do
          :ok -> {:ok, %{sql: query.raw, params: %{}, kind: :raw}}
          error -> error
        end
    end
  end

  defp compile_structured(state, query) do
    with :ok <- check_operators(query.filters),
         {:ok, {filter_sql, filter_params}} <- SQL.build_where(state.mapping, query.filters) do
      time_bound = "#{state.partition_key} BETWEEN {from:DateTime64(3)} AND {to:DateTime64(3)}"
      where_sql = if filter_sql == "", do: time_bound, else: time_bound <> " AND " <> filter_sql
      params = Map.merge(%{from: query.from, to: query.to}, filter_params)

      {sql, kind} =
        case query.mode do
          :summary ->
            {SQL.summary_sql(state.mapping, state.table_path, where_sql, query), :summary}

          :sample ->
            {SQL.sample_sql(state.mapping, state.table_path, where_sql, query), :records}

          :full ->
            {SQL.full_sql(state.mapping, state.table_path, where_sql, query), :records}
        end

      {:ok, %{sql: sql, params: params, kind: kind}}
    end
  end

  defp check_operators(filters) do
    Enum.find_value(filters, :ok, fn f ->
      if f.op in @operators, do: nil, else: {:error, {:unsupported_operator, f.op}}
    end)
  end

  @impl true
  def execute(state, %{sql: sql, params: params, kind: kind}) do
    case run(state, sql, params) do
      {:ok, %Ch.Result{columns: columns, rows: rows}} ->
        records = rows_to_output(kind, columns, rows)
        {:ok, %{records: records, native: to_string(sql), total: length(records)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def health(state) do
    case run(state, "SELECT 1", %{}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(state, sql, params) do
    case Ch.query(state.conn, sql, params, settings: state.settings, timeout: state.timeout_ms) do
      {:ok, result} -> {:ok, result}
      {:error, exception} -> {:error, {:clickhouse_error, Exception.message(exception)}}
    end
  end

  defp rows_to_output(:summary, _columns, rows) do
    Enum.map(rows, fn [bucket, severity, service, count] ->
      %{
        bucket: format_ts(bucket),
        severity: normalize_severity(severity),
        service: service,
        count: count
      }
    end)
  end

  defp rows_to_output(:records, _columns, rows) do
    Enum.map(rows, fn [ts, severity, body, service, trace_id, span_id, attributes] ->
      %Record{
        timestamp: format_ts(ts),
        severity: normalize_severity(severity),
        body: body,
        service: service,
        trace_id: nil_if_empty(trace_id),
        span_id: nil_if_empty(span_id),
        attributes: attributes || %{},
        source: ""
      }
    end)
  end

  defp rows_to_output(:raw, columns, rows) do
    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end

  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_ts(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt) <> "Z"
  defp format_ts(other), do: to_string(other)

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(other), do: other

  # OTel SeverityText is free-form; SeverityNumber follows the OTel spec's 1-24 range.
  # Unknown/missing values normalize to :info rather than raising — a malformed severity
  # column must never turn into a 500 on an otherwise-good log line.
  defp normalize_severity(sev) when is_binary(sev) do
    case String.downcase(sev) do
      "trace" -> :trace
      "debug" -> :debug
      "info" -> :info
      "information" -> :info
      "warn" -> :warn
      "warning" -> :warn
      "error" -> :error
      "fatal" -> :fatal
      "critical" -> :fatal
      _ -> :info
    end
  end

  defp normalize_severity(sev) when is_integer(sev) do
    cond do
      sev in 1..4 -> :trace
      sev in 5..8 -> :debug
      sev in 9..12 -> :info
      sev in 13..16 -> :warn
      sev in 17..20 -> :error
      sev in 21..24 -> :fatal
      true -> :info
    end
  end

  defp normalize_severity(_), do: :info
end
