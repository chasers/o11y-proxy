defmodule O11yProxy.Sources.StateTable do
  @moduledoc """
  Owns a public ETS table mapping source name -> `%{backend, backend_name, signal, state}`.

  Exists so query execution can read a source's adapter state without a `GenServer.call`
  round trip: "the source process is a policy
  holder, not a bottleneck" — one slow query must not block that source's own health
  checks or other queries. The `O11yProxy.Sources.Server` GenServer still owns the
  process lifecycle and writes/deletes its own entry; this table is purely a fast,
  concurrent read path.
  """

  use GenServer

  @table __MODULE__
  @breaker_table __MODULE__.Breakers

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    # Breaker state lives in its own table, keyed by the same source name, deliberately
    # *not* inside the entry above. Two reasons, both bugs waiting to happen otherwise:
    # a read-modify-write of the whole entry loses failure counts when concurrent fan-out
    # tasks update the same source, and it can resurrect a source whose `Sources.Server`
    # deleted its entry mid-flight (leaving a dead source visible in /v1/sources with a
    # stale adapter state). A separate table means only `{failures, open_until}` is ever
    # written from a query task, atomically, and lifecycle stays the GenServer's alone.
    :ets.new(@breaker_table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end

  @spec put(String.t(), map()) :: true
  def put(name, entry), do: :ets.insert(@table, {name, entry})

  @spec delete(String.t()) :: true
  def delete(name) do
    :ets.delete(@breaker_table, name)
    :ets.delete(@table, name)
  end

  @spec get(String.t()) :: {:ok, map()} | :error
  def get(name) do
    case :ets.lookup(@table, name) do
      [{^name, entry}] -> {:ok, entry}
      [] -> :error
    end
  end

  @spec all() :: [{String.t(), map()}]
  def all, do: :ets.tab2list(@table)

  @doc """
  Per-source circuit breaker state, stored on the same entry `Sources.Server` already
  writes (`put/2`) rather than a separate table or process —
  "policy holder, not a bottleneck": these are written
  directly from the supervised `Task` that runs a query in `O11yProxy.Sources.run_query/3`,
  with no `GenServer.call` round trip, so one hammered source's breaker bookkeeping never
  queues behind that source's own `:capabilities`/`:health` calls.

  `:closed` (never tripped, or the backoff has elapsed) vs `{:open, retry_after_ms}`
  (tripped, still cooling down).
  """
  # Entries are `{name, failures, open_until}`. `open_until` is `nil` (not `0`) when the
  # breaker has never tripped: monotonic time is allowed to be negative — and on this VM
  # it *is* (it starts around -576460751 seconds) — so a `0` sentinel would read as
  # "opens far in the future" and wedge every source shut on its first failure.
  @spec breaker_status(String.t()) :: :closed | {:open, pos_integer()}
  def breaker_status(name) do
    case :ets.lookup(@breaker_table, name) do
      [{^name, _failures, open_until}] when is_integer(open_until) ->
        remaining = open_until - System.monotonic_time(:millisecond)
        if remaining > 0, do: {:open, remaining}, else: :closed

      _ ->
        :closed
    end
  end

  @doc "Resets the failure count on a successful query — closes the breaker."
  @spec record_success(String.t()) :: :ok
  def record_success(name) do
    :ets.insert(@breaker_table, {name, 0, nil})
    :ok
  end

  @doc """
  Bumps the failure count on a failed query; once it reaches `threshold`, opens the
  breaker for `backoff_ms`. A success resets the count to zero (`record_success/1`), so
  the breaker only trips on *consecutive* failures.

  The increment is an atomic `:ets.update_counter/4` (inserting a default row if this is
  the source's first failure) rather than a read-modify-write, so concurrent fan-out
  tasks failing against the same source can't lose each other's counts.
  """
  @spec record_failure(String.t(), pos_integer(), pos_integer()) :: :ok
  def record_failure(name, threshold, backoff_ms) do
    failures = :ets.update_counter(@breaker_table, name, {2, 1}, {name, 0, nil})

    if failures >= threshold do
      open_until = System.monotonic_time(:millisecond) + backoff_ms
      :ets.update_element(@breaker_table, name, {3, open_until})
    end

    :ok
  end
end
