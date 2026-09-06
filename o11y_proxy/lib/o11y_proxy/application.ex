defmodule O11yProxy.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    config = O11yProxy.Config.load!()

    Application.put_env(:o11y_proxy, :auth, config.server.auth)
    Application.put_env(:o11y_proxy, :defaults, config.defaults)

    children = [
      {Registry, keys: :unique, name: O11yProxy.Sources.Registry},
      O11yProxy.Sources.StateTable,
      {DynamicSupervisor, strategy: :one_for_one, name: O11yProxy.Sources.Supervisor},
      {Task.Supervisor, name: O11yProxy.TaskSupervisor},
      {TelemetryMetricsPrometheus.Core, metrics: O11yProxy.Telemetry.metrics()},
      {Bandit, plug: O11yProxy.Router, ip: {127, 0, 0, 1}, port: config.server.port}
    ]

    opts = [strategy: :one_for_one, name: O11yProxy.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      O11yProxy.Sources.start_all(config.sources)
      Logger.info("o11y-proxy listening on http://127.0.0.1:#{config.server.port}")
      {:ok, pid}
    end
  end
end
