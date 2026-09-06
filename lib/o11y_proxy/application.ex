defmodule O11yProxy.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    config = load_config_or_exit()

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
      keep_alive_if_release()
      {:ok, pid}
    end
  end

  # A release boots via `-noshell -s elixir start_cli`, and Elixir's CLI halts the VM once
  # argv processing finishes — so a server release boots, logs "listening", and exits.
  # `mix release`'s own start script avoids this by passing `--no-halt`; a Burrito binary
  # passes the user's argv straight through instead, so a bare `./o11y-proxy` would exit
  # and the user would have to know to type `--no-halt` at a server. They shouldn't have to.
  #
  # `System.no_halt(true)` does not work here: `Kernel.CLI.main/1` *sets* that flag from
  # the parsed argv (defaulting to halt) after our application has already started, so it
  # overwrites anything we set during boot. Its `run/1` then checks the flag and, only if
  # halting, runs `at_exit` hooks and calls `System.halt/1`. So an `at_exit` hook is the
  # last point of control before the VM goes down — blocking there is what keeps a server
  # release alive.
  #
  # This does not interfere with shutdown: `at_exit` hooks are a `Kernel.CLI` concept, run
  # once on that startup path. SIGTERM and `:init.stop/0` don't go through them, so
  # ordinary OTP shutdown still stops the supervision tree and exits normally.
  #
  # Guarded on embedded mode (how releases run) so `mix run`/`mix test` — interactive, and
  # whose exit behavior we must not change — are unaffected.
  defp keep_alive_if_release do
    if :code.get_mode() == :embedded do
      System.at_exit(fn _status -> Process.sleep(:infinity) end)
    end
  end

  # Config problems are the likeliest first-run failure, especially for someone running a
  # downloaded single-file binary. Print something actionable and exit non-zero, rather
  # than raising — an exception here becomes an application_controller crash, several
  # screens of Erlang term dump, and an erl_crash.dump file in the user's cwd.
  defp load_config_or_exit do
    case O11yProxy.Config.load() do
      {:ok, config} ->
        config

      {:error, reason} ->
        IO.puts(:stderr, "o11y-proxy: " <> O11yProxy.Config.format_error(reason))
        System.halt(1)
    end
  end
end
