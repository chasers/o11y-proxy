defmodule O11yProxy.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    case O11yProxy.CLI.main(cli_argv()) do
      :serve -> start_server()
      status -> System.halt(status)
    end
  end

  # Under Mix — `mix run`, `mix test`, `iex -S mix` — the plain arguments belong to Mix,
  # not to us: `mix test some_test.exs` would otherwise look like a subcommand. Releases
  # don't ship Mix, which is the same signal keep_alive_if_release/0 uses below.
  defp cli_argv do
    if Code.ensure_loaded?(Mix), do: [], else: O11yProxy.CLI.argv()
  end

  @doc """
  Starts the core supervision tree *without* Bandit, plus the given sources — the CLI's
  in-process path (`.plans/07-cli.md`). No port is bound, both because a one-shot command
  needs none and because binding one would collide with a running daemon.
  """
  @spec start_core(O11yProxy.Config.t(), [O11yProxy.Config.Source.t()]) ::
          :ok | {:error, String.t()}
  def start_core(config, sources) do
    put_runtime_env(config)

    case Supervisor.start_link(core_children(),
           strategy: :one_for_one,
           name: O11yProxy.Supervisor
         ) do
      {:ok, _pid} ->
        O11yProxy.Sources.start_all(sources)
        :ok

      {:error, reason} ->
        {:error, "failed to start: #{inspect(reason)}"}
    end
  end

  defp start_server do
    config = load_config_or_exit()
    put_runtime_env(config)

    children =
      core_children() ++
        [{Bandit, plug: O11yProxy.Router, ip: {127, 0, 0, 1}, port: config.server.port}]

    opts = [strategy: :one_for_one, name: O11yProxy.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        O11yProxy.Sources.start_all(config.sources)
        Logger.info("o11y-proxy listening on http://127.0.0.1:#{config.server.port}")
        keep_alive_if_release()
        {:ok, pid}

      # Running it twice is an ordinary mistake and deserves an ordinary message, not the
      # same wall of Erlang term dump a config error used to produce.
      {:error, {:shutdown, {:failed_to_start_child, Bandit, _}}} ->
        IO.puts(
          :stderr,
          """
          o11y-proxy: port #{config.server.port} is already in use.

          Something else is listening there — most likely another o11y-proxy. Stop it, or
          set a different port in your config:

            server:
              port: 4001
          """
        )

        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "o11y-proxy: failed to start: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Everything the query path needs. Bandit is the *only* difference between a server and
  # a CLI run, which is what makes the two paths produce byte-identical output.
  defp core_children do
    [
      {Registry, keys: :unique, name: O11yProxy.Sources.Registry},
      O11yProxy.Sources.StateTable,
      {DynamicSupervisor, strategy: :one_for_one, name: O11yProxy.Sources.Supervisor},
      {Task.Supervisor, name: O11yProxy.TaskSupervisor},
      {TelemetryMetricsPrometheus.Core, metrics: O11yProxy.Telemetry.metrics()}
    ]
  end

  defp put_runtime_env(config) do
    Application.put_env(:o11y_proxy, :auth, config.server.auth)
    Application.put_env(:o11y_proxy, :defaults, config.defaults)
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
  # A CLI subcommand never gets here: it halts inside start/2, before `Kernel.CLI` runs at
  # all, which is also why an unrecognized argument never produces `No file named query`.
  #
  # This does not interfere with shutdown: `at_exit` hooks are a `Kernel.CLI` concept, run
  # once on that startup path. SIGTERM and `:init.stop/0` don't go through them, so
  # ordinary OTP shutdown still stops the supervision tree and exits normally.
  #
  # Guarded on "are we a release" so `mix run`/`mix test`, whose exit behavior we must not
  # change, are unaffected. The signal is whether Mix is loaded: releases don't ship it.
  #
  # Do *not* use `:code.get_mode() == :embedded` here, however plausible it looks. Burrito
  # passes `-mode embedded` to `erlexec` as a single argv string rather than two, so the
  # VM never actually enters embedded mode and the guard silently never fires — the binary
  # boots, logs "listening", and exits. That bug survived a local test that looked green
  # only because a stale process from an earlier run was still holding the port.
  #
  # Registering the hook in every release is safe: it only ever runs on `Kernel.CLI`'s halt
  # path, which a tarball release started via `bin/o11y_proxy start` never takes (that
  # script already passes `--no-halt`), and which `stop`/SIGTERM don't go through either.
  defp keep_alive_if_release do
    unless Code.ensure_loaded?(Mix) do
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
