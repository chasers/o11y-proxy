defmodule O11yProxy.Test.FakeBackend do
  @moduledoc """
  A minimal adapter that only exists to exercise `O11yProxy.BackendCase` before any real
  backend is built. Deliberately: builds a
  parameterized "SQL-ish" native query where every filter value lands only in `:params`,
  never spliced into the `:sql` text, and deliberately does *not* support `:regex` so the
  "rejects unsupported operator" contract test has something real to exercise.
  """

  @behaviour O11yProxy.Backend

  alias O11yProxy.Record

  @operators [:eq, :neq, :gte, :lte, :contains, :in, :exists]

  @impl true
  def config_schema do
    [
      table: [type: :string, required: true],
      allow_raw: [type: :boolean, default: false],
      # Test knobs: `fail` forces execute/2 to error (circuit-breaker and
      # partial-failure fan-out tests need deterministic failures), `trace_id` stamps a
      # shared trace ID across fakes so a /v1/context fan-out has something to correlate.
      fail: [type: :boolean, default: false],
      trace_id: [type: :string, default: "abc123"]
    ]
  end

  @impl true
  def init(config) do
    {:ok,
     %{
       table: Map.fetch!(config, :table),
       allow_raw: Map.get(config, :allow_raw, false),
       fail: Map.get(config, :fail, false),
       trace_id: Map.get(config, :trace_id, "abc123")
     }}
  end

  @impl true
  def capabilities(_state) do
    %{
      signals: [:logs],
      operators: @operators,
      modes: [:summary, :sample, :full],
      raw: false,
      max_window_ms: :infinity
    }
  end

  @impl true
  def schema(_state), do: {:ok, %{fields: []}}

  @impl true
  def compile(state, query) do
    with :ok <- check_operators(query.filters) do
      {clauses, params} = build_where(query.filters)

      limit = if query.mode != :summary, do: query.limit, else: 50

      sql =
        [
          "SELECT * FROM #{state.table}",
          "WHERE ts BETWEEN {from:DateTime} AND {to:DateTime}",
          Enum.map_join(clauses, &" AND #{&1}"),
          "LIMIT #{limit}"
        ]
        |> Enum.join(" ")

      native = %{sql: sql, params: Map.merge(%{from: query.from, to: query.to}, params)}
      {:ok, native}
    end
  end

  @impl true
  def execute(%{fail: true}, _native),
    do: {:error, {:fake_unreachable, "fake backend set to fail"}}

  def execute(state, native) do
    records = [
      %Record{
        timestamp: DateTime.to_iso8601(DateTime.utc_now()),
        severity: :info,
        body: "fake record 1",
        service: "fake-service",
        trace_id: nil,
        span_id: nil,
        attributes: %{},
        source: "fake_backend"
      },
      %Record{
        timestamp: DateTime.to_iso8601(DateTime.utc_now()),
        severity: :error,
        body: "fake record 2",
        service: "fake-service",
        trace_id: state.trace_id,
        span_id: "def456",
        attributes: %{"k" => "v"},
        source: "fake_backend"
      }
    ]

    {:ok, %{records: records, native: native.sql, total: length(records)}}
  end

  @impl true
  def health(_state), do: :ok

  defp check_operators(filters) do
    Enum.find_value(filters, :ok, fn f ->
      if f.op in @operators, do: nil, else: {:error, {:unsupported_operator, f.op}}
    end)
  end

  defp build_where(filters) do
    filters
    |> Enum.with_index(1)
    |> Enum.map_reduce(%{}, fn {filter, i}, params ->
      # `:"p#{i}"` rather than String.to_atom, matching ClickHouse.SQL.clause_for/3 — the
      # index is ours, not the caller's, so the atom set is bounded by filters-per-query.
      key = :"p#{i}"
      {clause, value} = clause_for(filter, key)
      {clause, Map.put(params, key, value)}
    end)
  end

  defp clause_for(%{field: field, op: :eq, value: v}, key), do: {"#{field} = {#{key}:String}", v}

  defp clause_for(%{field: field, op: :neq, value: v}, key),
    do: {"#{field} != {#{key}:String}", v}

  defp clause_for(%{field: field, op: :gte, value: v}, key),
    do: {"#{field} >= {#{key}:String}", v}

  defp clause_for(%{field: field, op: :lte, value: v}, key),
    do: {"#{field} <= {#{key}:String}", v}

  defp clause_for(%{field: field, op: :contains, value: v}, key),
    do: {"#{field} LIKE {#{key}:String}", "%#{v}%"}

  defp clause_for(%{field: field, op: :in, value: v}, key),
    do: {"#{field} IN {#{key}:Array(String)}", List.wrap(v)}

  defp clause_for(%{field: field, op: :exists}, _key), do: {"isNotNull(#{field})", nil}
end
