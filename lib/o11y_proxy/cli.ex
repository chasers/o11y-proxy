defmodule O11yProxy.CLI do
  @moduledoc """
  The one-shot command surface from `.plans/07-cli.md`: `o11y-proxy context --trace-id X`
  instead of "write a config, start a daemon, keep it running, curl a port".

  ## Why this lives in `Application.start/2`

  Burrito passes the user's argv straight through to the BEAM as Erlang plain arguments,
  and `Kernel.CLI.main/1` parses them too — an unrecognized first argument becomes
  `{:file, "query"}`, prints `No file named query`, and calls `System.halt(1)` on a path
  that skips `at_exit`, so the server's keep-alive hook cannot rescue it.

  What saves us is ordering: the boot script runs `Application.start/2` *before*
  `-s elixir start_cli`. So `Application.start/2` is the CLI entry point, and a subcommand
  must finish its work and halt before returning — then `Kernel.CLI` never runs and never
  sees our arguments. Two consequences show up in this module:

    * `--help`/`--version` are ours (`O11yProxy.CLI.Args`). If control ever reached
      `Kernel.CLI` it would swallow `-h`, `-v`, `--version`, `-e`, `-r`, `-S`, `--no-halt`
      and `-pa`/`-pz`.
    * argv is read with `:init.get_plain_arguments/0`, not `Burrito.Util.Args.argv/0`:
      `burrito` is `runtime: false` in `mix.exs` and is not in the built release. That
      helper is this one-liner anyway.

  `maintenance` is additionally reserved — Burrito intercepts it in Zig before the BEAM
  boots — so it never reaches `Args`.

  ## Never Bandit

  A CLI run starts the core supervision tree *minus* the HTTP server: it needs no port,
  and binding one would collide with a daemon that is already running.
  """

  alias O11yProxy.CLI.Args

  # Generous on purpose: the daemon may legitimately be waiting on a slow backend, and its
  # own per-source deadlines are what should decide when a query gives up — not this hop.
  @call_timeout 60_000

  @doc """
  argv → an exit status, or `:serve` when the arguments name the server.

  Returning `:serve` rather than starting one keeps this function pure enough to test:
  `O11yProxy.Application` owns process trees, this owns the command surface.
  """
  @spec main([String.t()]) :: :serve | non_neg_integer()
  def main(argv) when is_list(argv) do
    case Args.parse(argv) do
      {:ok, %{command: :serve}} ->
        :serve

      {:ok, command} ->
        run(command)

      # trim_trailing so both help (a heredoc, already newline-terminated) and the
      # one-line version string end with exactly one newline.
      {:print, text} ->
        IO.puts(String.trim_trailing(text))
        0

      {:error, message} ->
        IO.puts(:stderr, "o11y-proxy: " <> message)
        1
    end
  end

  @doc "The user's arguments, as the BEAM received them."
  @spec argv() :: [String.t()]
  def argv, do: Enum.map(:init.get_plain_arguments(), &to_string/1)

  @doc """
  The arguments that are *ours*, or `[]` when this VM's arguments belong to Elixir.

  Not everything in `:init.get_plain_arguments/0` was typed by the user. A release start
  script runs `elixir --no-halt …` (see `bin/o11y_proxy`), and that `--no-halt` arrives
  here looking exactly like a subcommand would — which made `bin/o11y_proxy start` fail
  with `unknown command: --no-halt` until this existed.

  So: anything beginning with `-` belongs to `Kernel.CLI`, not to us, and means "no
  command was given" — the server. The exception is the four flags we deliberately take
  over, because `Kernel.CLI` would otherwise swallow them. A bare word is always ours: it
  is a subcommand, or a typo of one that deserves a real error rather than a silent server
  start.
  """
  @spec command_argv() :: [String.t()]
  def command_argv, do: command_argv(argv())

  @doc "`command_argv/0` against a given argv. Separated so it's testable without a VM."
  @spec command_argv([String.t()]) :: [String.t()]
  def command_argv([flag | _] = args) when flag in ["-h", "--help", "-v", "--version"], do: args
  def command_argv(["-" <> _ | _]), do: []
  def command_argv(args), do: args

  # Under `mix run`/`mix test` the whole tree is already up, sources and all. Use it
  # directly: a test driving main/1 wants the sources it registered, not a second copy
  # started from whatever o11y.yaml is in the working directory, and certainly not a
  # daemon on someone's machine.
  defp run(command) do
    if core_running?() do
      command |> request() |> O11yProxy.Remote.handle() |> emit(command)
    else
      standalone(command)
    end
  end

  defp standalone(command) do
    case load_config() do
      {:ok, config} ->
        case connect(config) do
          {:ok, node} -> via_daemon(node, command, config)
          {:fallback, reason} -> in_process(command, config, reason)
        end

      {:error, message} ->
        fail(message)
    end
  end

  defp via_daemon(node, command, config) do
    request = request(command)

    # The daemon was there a moment ago and isn't now, or the call blew up inside it.
    # Falling back beats handing the user an Erlang term: the in-process path always
    # produces the correct answer, just more slowly.
    #
    # Both clauses are needed. `:erpc.call/5` signals `{:erpc, :noconnection | :timeout |
    # :badarg}` and a remote *raise* as `error:` — an ErlangError here — but a remote
    # process that **exits** comes back as `exit:{:exception, reason}`, which no `rescue`
    # clause ever sees. Catching only the first would have crashed the CLI on the second.
    try do
      :erpc.call(node, O11yProxy.Remote, :handle, [request], @call_timeout)
    rescue
      error in [ErlangError] -> {:fallback, {:call_failed, Exception.message(error)}}
    catch
      :exit, reason -> {:fallback, {:call_failed, inspect(reason)}}
    end
    |> case do
      {:fallback, reason} -> in_process(command, config, reason)
      result -> emit(result, command)
    end
  end

  defp in_process(command, config, reason) do
    case O11yProxy.Application.start_core(config, sources_for(command, config)) do
      :ok ->
        status = command |> request() |> O11yProxy.Remote.handle() |> emit(command)
        note(reason, command)
        status

      {:error, message} ->
        fail(message)
    end
  end

  defp request(command),
    do: %{"command" => Atom.to_string(command.command), "request" => command.request}

  defp fail(message) do
    IO.puts(:stderr, "o11y-proxy: " <> message)
    1
  end

  # `{:ok, _}` is exit 0 even when the body carries entries in `errors[]` — that's a
  # partial answer, the normal path for a source that's down, and it matches the HTTP
  # 200 the same result gets. Structured errors go to stderr so a `| jq` on stdout never
  # sees a body that isn't the result it asked for.
  defp emit({:ok, body}, command) do
    IO.puts(encode(body, command.pretty))
    0
  end

  defp emit({:error, body}, command) do
    IO.puts(:stderr, encode(body, command.pretty))
    1
  end

  defp encode(body, true), do: Jason.encode!(body, pretty: true)
  defp encode(body, false), do: Jason.encode!(body)

  defp core_running?, do: is_pid(Process.whereis(O11yProxy.Sources.Supervisor))

  # Connect, or say why not. Every `{:fallback, _}` is a normal outcome, never an error:
  # the in-process path produces the same answer, so a missing or mismatched daemon must
  # never turn into a failed command.
  defp connect(%{server: %{distribution: false}}), do: {:fallback, :disabled}

  defp connect(config) do
    daemon = O11yProxy.Remote.node_name(config)

    with :ok <- start_distribution(),
         true <- Node.connect(daemon) do
      check_protocol(daemon)
    else
      {:error, reason} -> {:fallback, {:no_distribution, reason}}
      # `false` (no such node) and `:ignored` (our own distribution went away).
      _ -> {:fallback, :no_daemon}
    end
  end

  # A throwaway name per invocation, unique across concurrent CLI runs — the OS pid alone
  # is not enough, since a pid is reused once the process that held it exits.
  defp start_distribution do
    unique = System.unique_integer([:positive])
    O11yProxy.Remote.start_distribution(:"o11y_cli_#{System.pid()}_#{unique}@127.0.0.1")
  end

  # Version skew is contained by checking the *protocol* number, not the app version: it
  # moves only when handle/1's contract does, so an 0.1.0 CLI keeps using an 0.1.4 daemon
  # instead of cold-starting on every patch release. A daemon predating this feature has
  # no protocol_version/0 at all, which :erpc raises on — also a fallback, not a crash.
  defp check_protocol(daemon) do
    ours = O11yProxy.Remote.protocol_version()

    case :erpc.call(daemon, O11yProxy.Remote, :protocol_version, [], @call_timeout) do
      ^ours -> {:ok, daemon}
      theirs -> {:fallback, {:protocol_mismatch, ours, theirs}}
    end
  rescue
    # An undefined protocol_version/0 — a daemon predating the CLI — is an ErlangError
    # carrying `{:exception, %UndefinedFunctionError{}}`. See via_daemon/3 on why the
    # exit clause is not optional.
    ErlangError -> {:fallback, {:protocol_unknown, O11yProxy.Remote.protocol_version()}}
  catch
    :exit, _reason -> {:fallback, {:protocol_unknown, O11yProxy.Remote.protocol_version()}}
  end

  # Nothing in the output reveals that a command paid a cold BEAM start plus fresh
  # connections to every source it touched, so say so — with the measured time, so the
  # claim is concrete rather than nagging.
  #
  # Only when stdout is a terminal, which is what Burrito's wrapper reports in `_IS_TTY`
  # (`deps/burrito/src/wrapper.zig:111-116`). An agent or a `| jq` gets nothing extra; a
  # human running it by hand discovers the daemon exists. `--quiet` suppresses it either
  # way, and the daemon path never prints it.
  defp note(reason, command) do
    with false <- command.quiet,
         "1" <- System.get_env("_IS_TTY"),
         message when is_binary(message) <- describe(reason) do
      IO.puts(:stderr, "note: #{message} — ran in-process in #{elapsed()}.")
      IO.puts(:stderr, "      `o11y-proxy serve` in another terminal keeps connections warm.")
    else
      _ -> :ok
    end
  end

  # `server.distribution: false` is the documented off switch. Someone who set it does not
  # need to be told about it on every invocation.
  defp describe(:disabled), do: nil
  # `Node.connect/1` answers `false` for "no such node" and for a rejected cookie alike —
  # the distinction is not available at this layer, so the note names both rather than
  # asserting the one that is only usually right.
  defp describe(:no_daemon), do: "no daemon running (or its cookie doesn't match)"

  defp describe({:no_distribution, reason}),
    do: "could not start Erlang distribution (#{inspect(reason)})"

  defp describe({:protocol_mismatch, ours, theirs}),
    do: "the running daemon speaks protocol #{inspect(theirs)}, this binary speaks #{ours}"

  defp describe({:protocol_unknown, ours}),
    do: "the running daemon predates protocol #{ours} and can't be called"

  defp describe({:call_failed, message}), do: "the daemon call failed (#{message})"

  # Wall clock since the VM started, which is the number that matters: the cold BEAM boot
  # is most of what a daemon would have saved, and it happened before this code ran.
  defp elapsed do
    {total_ms, _since_last} = :erlang.statistics(:wall_clock)
    :erlang.float_to_binary(total_ms / 1000, decimals: 1) <> "s"
  end

  defp load_config do
    case O11yProxy.Config.load() do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, O11yProxy.Config.format_error(reason)}
    end
  end

  # Connecting to a source costs a round trip, so start only the ones the command can
  # actually reach: `query` and `schema` name exactly one; `context`, `sources` and
  # `health` fan out or enumerate and need them all. Naming a source that isn't
  # configured starts nothing and falls through to the same `not_found` the HTTP API
  # gives — the check stays in one place.
  defp sources_for(%{command: :query, request: %{"sources" => names}}, config),
    do: Enum.filter(config.sources, &(&1.name in names))

  defp sources_for(%{command: :schema, request: %{"source" => name}}, config),
    do: Enum.filter(config.sources, &(&1.name == name))

  defp sources_for(_command, config), do: config.sources
end
