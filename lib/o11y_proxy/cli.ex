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

  defp run(command) do
    case ensure_core(command) do
      :ok ->
        %{"command" => Atom.to_string(command.command), "request" => command.request}
        |> O11yProxy.Remote.handle()
        |> emit(command)

      {:error, message} ->
        IO.puts(:stderr, "o11y-proxy: " <> message)
        1
    end
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

  # Under `mix run`/`mix test` the whole tree is already up, sources and all, and a test
  # driving main/1 wants the sources it registered — not a second copy started from
  # whatever o11y.yaml happens to be in the working directory.
  defp ensure_core(command) do
    if core_running?() do
      :ok
    else
      with {:ok, config} <- load_config() do
        O11yProxy.Application.start_core(config, sources_for(command, config))
      end
    end
  end

  defp core_running?, do: is_pid(Process.whereis(O11yProxy.Sources.Supervisor))

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
