defmodule O11yProxy.Sources do
  @moduledoc """
  Facade over the configured sources: starting them under the `DynamicSupervisor`,
  discovery (`/v1/sources`, `/v1/sources/:name/schema`, `/healthz`), and running a query
  against one source's adapter state without serializing through its `GenServer`.
  """

  alias O11yProxy.Config.Source
  alias O11yProxy.Sources.StateTable

  # Trips the breaker after this many *consecutive* failures for a source, per
  # .plans/04-cross-cutting.md; overridable so tests don't have to wait out the real
  # backoff (`Application.put_env(:o11y_proxy, :breaker, threshold: 2, backoff_ms: 50)`).
  @breaker_defaults [threshold: 5, backoff_ms: 30_000]

  @doc "Starts one supervised `Sources.Server` per configured source."
  @spec start_all([Source.t()]) :: :ok
  def start_all(sources) do
    Enum.each(sources, fn source ->
      case DynamicSupervisor.start_child(
             O11yProxy.Sources.Supervisor,
             {O11yProxy.Sources.Server, source}
           ) do
        {:ok, _pid} -> :ok
        {:error, reason} -> raise "failed to start source #{source.name}: #{inspect(reason)}"
      end
    end)
  end

  @doc "Configured sources, their signal, and capabilities — the `/v1/sources` payload."
  @spec list() :: [map()]
  def list do
    StateTable.all()
    |> Enum.map(fn {name,
                    %{backend: backend, backend_name: backend_name, signal: signal, state: state}} ->
      %{
        name: name,
        backend: backend_name,
        signal: signal,
        capabilities: backend.capabilities(state)
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Canonical<->native field map for one source — `/v1/sources/:name/schema`."
  @spec schema(String.t()) :: {:ok, map()} | {:error, :not_found | :not_supported | term()}
  def schema(name) do
    with {:ok, %{backend: backend, state: state}} <- fetch(name) do
      if function_exported?(backend, :schema, 1) do
        backend.schema(state)
      else
        {:error, :not_supported}
      end
    end
  end

  @doc "Per-source reachability — the `/healthz` payload."
  @spec healthz() :: %{sources: %{optional(String.t()) => map()}}
  def healthz do
    statuses =
      StateTable.all()
      |> Map.new(fn {name, %{backend: backend, state: state}} ->
        {name, health_status(backend, state)}
      end)

    %{sources: statuses}
  end

  defp health_status(backend, state) do
    if function_exported?(backend, :health, 1) do
      case backend.health(state) do
        :ok -> %{status: "ok"}
        {:error, reason} -> %{status: "error", message: inspect(reason)}
      end
    else
      %{status: "ok"}
    end
  end

  @doc """
  Every configured source as `%{name, backend, backend_name, signal, state}` — the
  internal shape (adapter module + state), unlike `list/0`'s public `/v1/sources`
  payload. Used by `O11yProxy.Context`'s fan-out, which needs to group sources by signal
  and call adapter callbacks directly.
  """
  @spec entries() :: [map()]
  def entries do
    StateTable.all()
    |> Enum.map(fn {name, entry} -> Map.put(entry, :name, name) end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "This source's circuit breaker state — see `O11yProxy.Sources.StateTable`."
  @spec breaker_status(String.t()) :: :closed | {:open, pos_integer()}
  defdelegate breaker_status(name), to: StateTable

  @doc false
  @spec fetch(String.t()) :: {:ok, map()} | {:error, :not_found}
  def fetch(name) do
    case StateTable.get(name) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Compiles and executes a query against one source, in a supervised `Task` — per
  "Process model" in `.plans/02-backend-behaviour.md`, a slow query must not block that
  source's own health checks or other queries. Every returned record is stamped with the
  *configured source name* (not the backend type), since the adapter itself has no
  business knowing it.

  Checks the source's circuit breaker first (`StateTable.breaker_status/1`) — if open,
  fails fast with `{:error, {:circuit_open, retry_after_ms}}` without touching
  `compile/2`/`execute/2` at all, per "fail fast into the errors array rather than
  burning the caller's timeout budget" (`.plans/04-cross-cutting.md`). A successful
  execute closes the breaker; a failure (including a timeout) bumps its failure count.
  """
  @spec run_query(String.t(), O11yProxy.Query.t(), timeout()) ::
          {:ok,
           %{
             records: [map()],
             native: String.t(),
             total: non_neg_integer() | nil,
             cursor: String.t() | nil
           }}
          | {:error, term()}
  def run_query(name, query, timeout \\ 30_000) do
    case StateTable.breaker_status(name) do
      {:open, retry_after_ms} ->
        {:error, {:circuit_open, retry_after_ms}}

      :closed ->
        do_run_query(name, query, timeout)
    end
  end

  # Only *execution* failures move the breaker. A `compile/2` error means the caller asked
  # for something this adapter can't express (`{:unknown_field, _}`,
  # `{:unsupported_operator, _}`, a bad cursor) — the backend was never contacted and is
  # not unhealthy. Counting those would be actively wrong here: `/v1/context`'s
  # `{from, to, service}` fan-out *deliberately* sends every source the same `service`
  # filter and expects the ones that can't express it (Sentry) to say so, so a handful of
  # those requests would otherwise trip a perfectly healthy source's breaker and make it
  # report `unreachable` for the next 30s.
  defp do_run_query(name, query, timeout) do
    with {:ok, %{backend: backend, state: state}} <- fetch(name),
         {:ok, native} <- backend.compile(state, query) do
      case execute_in_task(backend, state, native, timeout) do
        {:ok, result} ->
          StateTable.record_success(name)

          {:ok,
           %{
             records: Enum.map(result.records, &stamp_source(&1, name)),
             native: result.native,
             total: result.total,
             cursor: Map.get(result, :cursor)
           }}

        {:error, _reason} = error ->
          record_failure(name)
          error
      end
    end
  end

  defp record_failure(name) do
    config = Application.get_env(:o11y_proxy, :breaker, @breaker_defaults)
    threshold = Keyword.get(config, :threshold, @breaker_defaults[:threshold])
    backoff_ms = Keyword.get(config, :backoff_ms, @breaker_defaults[:backoff_ms])
    StateTable.record_failure(name, threshold, backoff_ms)
  end

  defp execute_in_task(backend, state, native, timeout) do
    task =
      Task.Supervisor.async_nolink(O11yProxy.TaskSupervisor, fn ->
        backend.execute(state, native)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp stamp_source(%O11yProxy.Record{} = record, name), do: %{record | source: name}
  defp stamp_source(record, name) when is_map(record), do: Map.put(record, :source, name)
end
