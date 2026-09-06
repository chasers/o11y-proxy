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
    if Code.ensure_loaded?(Mix), do: [], else: O11yProxy.CLI.command_argv()
  end

  @doc """
  Starts the core supervision tree *without* Bandit, plus the given sources — the CLI's
  in-process path. No port is bound, both because a one-shot command needs none and
  because binding one would collide with a running daemon.
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
    start_distribution(config)

    children =
      core_children() ++
        [{Bandit, plug: O11yProxy.Router, ip: {127, 0, 0, 1}, port: config.server.port}]

    opts = [strategy: :one_for_one, name: O11yProxy.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        O11yProxy.Sources.start_all(config.sources)
        Logger.info("o11y-proxy listening on http://127.0.0.1:#{config.server.port}")
        keep_alive_if_release()
        block_if_bare_argument()
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

  # Distribution isn't on by default: Burrito's launcher passes `-setcookie` but no
  # `-name`/`-sname`, and the release vm.args sets neither, so the binary otherwise runs
  # as :nonode@nohost. Starting it here is what lets a CLI invocation find this daemon and
  # reuse its warm connections instead of paying a cold start.
  #
  # Failure is not fatal. A daemon that cannot start distribution — no epmd, a port
  # already taken, a hostile sandbox — still serves HTTP perfectly well; the only cost is
  # that CLI invocations run in-process. Log it and carry on rather than refusing to boot
  # over a convenience feature.
  #
  # Not under Mix, though. Distribution exists purely so a CLI *binary* can find a daemon,
  # and a binary's cookie never matches a `mix run` one anyway — so starting it here would
  # buy nothing and cost plenty: `mix test` would spawn epmd, become a named node, and
  # collide with a real daemon on the same port whenever a developer had one running.
  defp start_distribution(%{server: %{distribution: false}}), do: :ok

  defp start_distribution(config) do
    unless Code.ensure_loaded?(Mix) do
      node = O11yProxy.Remote.node_name(config)

      case O11yProxy.Remote.start_distribution(node) do
        # `node()`, not `node` — a tarball release is already distributed under the name its
        # start script chose, in which case start_distribution/1 succeeds without renaming
        # anything and the derived name would be a lie.
        :ok ->
          Logger.info("o11y-proxy node #{node()} — the CLI will use this daemon")

        {:error, reason} ->
          Logger.warning(
            "o11y-proxy could not start Erlang distribution (#{inspect(reason)}); " <>
              "the CLI will run its commands in-process"
          )
      end
    end
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

  # ...but the at_exit hook is not enough on its own, because it is only reached when
  # `Kernel.CLI` had nothing to complain about. An explicit `o11y-proxy serve` arrives as
  # a plain argument, becomes `{:file, "serve"}`, and takes the error path in
  # `Kernel.CLI.main/1` — which calls `System.halt(1)` *inside* the command runner, before
  # `run/1` ever gets to `at_exit` (see `Kernel.CLI.run/1`). Verified on the built binary:
  # it logged "listening", printed `No file named serve`, and died.
  #
  # So when there are plain arguments at all, don't return. Blocking here means
  # `Application.start/2` never completes, the boot script never reaches
  # `-s elixir start_cli`, and `Kernel.CLI` never runs. The supervision tree is already up
  # and serving — `Supervisor.start_link/2` returned above — and `init` runs the boot
  # script in a separate process, so it stays responsive and SIGTERM still shuts down
  # cleanly.
  #
  # Only for a *bare word*, which is precisely what becomes `{:file, _}`. A leading `-`
  # is an option `Kernel.CLI` understands and won't error on — which matters, because the
  # tarball's `bin/o11y_proxy start` passes `--no-halt`, and blocking there would stop the
  # application ever reporting itself started. A bare `./o11y-proxy` and `mix run` have no
  # plain arguments at all and take the at_exit path above. A CLI subcommand reaches
  # neither: it halts inside `start/2`.
  #
  # Note that `--no-halt` does *not* rescue a bare word: `Kernel.CLI.main/1` calls
  # `System.halt(1)` on a command error unconditionally, before `run/1` consults the flag.
  defp block_if_bare_argument do
    bare? = Enum.any?(O11yProxy.CLI.argv(), &(not String.starts_with?(&1, "-")))

    if bare? and not Code.ensure_loaded?(Mix) do
      Process.sleep(:infinity)
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
