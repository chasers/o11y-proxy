defmodule O11yProxy.Sources do
  @moduledoc """
  Facade over the configured sources: starting them under the `DynamicSupervisor`,
  discovery (`/v1/sources`, `/v1/sources/:name/schema`, `/healthz`), and running a query
  against one source's adapter state without serializing through its `GenServer`.
  """

  alias O11yProxy.Config.Source
  alias O11yProxy.Sources.StateTable

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
  """
  @spec run_query(String.t(), O11yProxy.Query.t(), timeout()) ::
          {:ok, %{records: [map()], native: String.t(), total: non_neg_integer() | nil}}
          | {:error, term()}
  def run_query(name, query, timeout \\ 30_000) do
    with {:ok, %{backend: backend, state: state}} <- fetch(name),
         {:ok, native} <- backend.compile(state, query),
         {:ok, result} <- execute_in_task(backend, state, native, timeout) do
      {:ok, %{result | records: Enum.map(result.records, &stamp_source(&1, name))}}
    end
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
