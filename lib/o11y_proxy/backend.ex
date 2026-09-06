defmodule O11yProxy.Backend do
  @moduledoc """
  The plugin contract every adapter (ClickHouse, VictoriaMetrics, Sentry, ...) implements.
  See `.plans/02-backend-behaviour.md` for the design rationale — in particular, why
  `compile/2` and `execute/2` are separate callbacks: compilation is pure, carries all the
  injection/correctness risk, and is the seam that makes `meta.native_queries` and
  exhaustive adapter tests possible without network mocking. Do not collapse the two.

  Every adapter must also pass `O11yProxy.BackendCase`, the shared contract test suite.
  """

  alias O11yProxy.Query

  @type state :: term()
  @type signal :: :logs | :metrics | :traces | :errors
  @type mode :: :summary | :sample | :full

  @type capabilities :: %{
          signals: [signal()],
          operators: [atom()],
          modes: [mode()],
          raw: boolean(),
          max_window_ms: pos_integer() | :infinity
        }

  @doc "NimbleOptions schema for this backend's source config block. Validated at boot."
  @callback config_schema() :: keyword()

  @doc "Build per-source state: creds, client, field mapping. Must not do network I/O."
  @callback init(config :: map()) :: {:ok, state()} | {:error, term()}

  @doc "What this source can do. Drives request validation and fan-out routing. Pure."
  @callback capabilities(state()) :: capabilities()

  @doc "Canonical<->native field map, filterable fields, cardinality hints. May hit network."
  @callback schema(state()) :: {:ok, map()} | {:error, term()}

  @doc "Compile a canonical query to a native one. Pure — this is the unit-test seam."
  @callback compile(state(), Query.t()) :: {:ok, native :: term()} | {:error, term()}

  @doc """
  Execute a compiled query. Returns records plus the native query text.

  `:records` is `[O11yProxy.Record.t()]` for `:sample`/`:full` mode. For `:summary` mode
  it's the time-bucketed aggregate rows described in `.plans/01-agent-contract.md`
  (`%{bucket:, severity:, service:, count:, ...}`) — summary output is intentionally not
  canonical-record-shaped, since it never carries `body`/`trace_id`/etc. `BackendCase`
  only checks canonical-record shape against a non-summary query.
  """
  @callback execute(state(), native :: term()) ::
              {:ok,
               %{
                 records: [O11yProxy.Record.t()] | [map()],
                 native: String.t(),
                 total: non_neg_integer() | nil
               }}
              | {:error, term()}

  @doc "Cheap liveness check for /healthz."
  @callback health(state()) :: :ok | {:error, term()}

  @optional_callbacks schema: 1, health: 1
end
