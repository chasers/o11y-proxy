defmodule O11yProxy.Sources.Server do
  @moduledoc """
  One GenServer per configured source (not per backend module), registered under
  `O11yProxy.Sources.Registry` and supervised by `O11yProxy.Sources.Supervisor`. Holds
  the adapter state built by `backend.init/1` and publishes it to
  `O11yProxy.Sources.StateTable` so query execution can read it without going through
  this process.
  """

  use GenServer, restart: :transient
  require Logger

  alias O11yProxy.Config.Source
  alias O11yProxy.Sources.StateTable

  defstruct [:name, :backend, :backend_name, :signal, :state]

  @spec start_link(Source.t()) :: GenServer.on_start()
  def start_link(%Source{} = source) do
    GenServer.start_link(__MODULE__, source, name: via(source.name))
  end

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(name), do: {:via, Registry, {O11yProxy.Sources.Registry, name}}

  @impl true
  def init(%Source{} = source) do
    Process.flag(:trap_exit, true)

    case source.backend.init(source.opts) do
      {:ok, state} ->
        entry = %{
          backend: source.backend,
          backend_name: source.backend_name,
          signal: source.signal,
          state: state
        }

        StateTable.put(source.name, entry)

        {:ok,
         %__MODULE__{
           name: source.name,
           backend: source.backend,
           backend_name: source.backend_name,
           signal: source.signal,
           state: state
         }}

      {:error, reason} ->
        Logger.error("source #{source.name} failed to initialize: #{inspect(reason)}")
        {:stop, {:backend_init_failed, source.name, reason}}
    end
  end

  @impl true
  def terminate(_reason, %__MODULE__{name: name}) do
    StateTable.delete(name)
    :ok
  end

  @impl true
  def handle_call(:capabilities, _from, s) do
    {:reply, s.backend.capabilities(s.state), s}
  end

  def handle_call(:schema, _from, s) do
    reply =
      if function_exported?(s.backend, :schema, 1),
        do: s.backend.schema(s.state),
        else: {:error, :not_supported}

    {:reply, reply, s}
  end

  def handle_call(:health, _from, s) do
    reply = if function_exported?(s.backend, :health, 1), do: s.backend.health(s.state), else: :ok
    {:reply, reply, s}
  end

  def handle_call(:info, _from, s) do
    {:reply, %{name: s.name, backend_name: s.backend_name, signal: s.signal}, s}
  end
end
