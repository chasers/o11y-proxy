defmodule O11yProxy.Sources.StateTable do
  @moduledoc """
  Owns a public ETS table mapping source name -> `%{backend, backend_name, signal, state}`.

  Exists so query execution can read a source's adapter state without a `GenServer.call`
  round trip: per `.plans/02-backend-behaviour.md`, "the source process is a policy
  holder, not a bottleneck" — one slow query must not block that source's own health
  checks or other queries. The `O11yProxy.Sources.Server` GenServer still owns the
  process lifecycle and writes/deletes its own entry; this table is purely a fast,
  concurrent read path.
  """

  use GenServer

  @table __MODULE__

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @spec put(String.t(), map()) :: true
  def put(name, entry), do: :ets.insert(@table, {name, entry})

  @spec delete(String.t()) :: true
  def delete(name), do: :ets.delete(@table, name)

  @spec get(String.t()) :: {:ok, map()} | :error
  def get(name) do
    case :ets.lookup(@table, name) do
      [{^name, entry}] -> {:ok, entry}
      [] -> :error
    end
  end

  @spec all() :: [{String.t(), map()}]
  def all, do: :ets.tab2list(@table)
end
