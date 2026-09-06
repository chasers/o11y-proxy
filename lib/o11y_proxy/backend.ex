defmodule O11yProxy.Backend do
  @moduledoc """
  Every adapter (ClickHouse, VictoriaMetrics, Sentry, ...) implements these callbacks.
  Why
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
  it's the time-bucketed aggregate rows
  (`%{bucket:, severity:, service:, count:, ...}`) — summary output is intentionally not
  canonical-record-shaped, since it never carries `body`/`trace_id`/etc. `BackendCase`
  only checks canonical-record shape against a non-summary query.

  The result map may also carry a `:cursor` key — an opaque token (see
  `O11yProxy.Cursor`) for the next page, present only when there's more data and the
  adapter supports pagination. Absent (the default for any adapter that doesn't set it)
  means "no more pages" / "pagination not supported" —
  callers must not distinguish the two.
  """
  @callback execute(state(), native :: term()) ::
              {:ok,
               %{
                 required(:records) => [O11yProxy.Record.t()] | [map()],
                 required(:native) => String.t(),
                 required(:total) => non_neg_integer() | nil,
                 optional(:cursor) => String.t()
               }}
              | {:error, term()}

  @doc "Cheap liveness check for /healthz."
  @callback health(state()) :: :ok | {:error, term()}

  @doc """
  Fetch a single record by its backend-native ID — e.g. a Sentry issue ID for
  `POST /v1/context {"error_id": ...}`. Optional:
  only makes sense for `:errors`-signal backends with an ID-addressable lookup; most
  adapters won't implement it. `O11yProxy.Context` tries every configured `:errors`
  source that exports this, first match wins.
  """
  @callback fetch_by_id(state(), id :: String.t()) ::
              {:ok, O11yProxy.Record.t()} | {:error, term()}

  @optional_callbacks schema: 1, health: 1, fetch_by_id: 2
end
