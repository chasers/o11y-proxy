defmodule O11yProxy.CLITest do
  @moduledoc """
  Drives `O11yProxy.CLI.main/1` in-process against the same `FakeBackend` fixtures
  `router_test.exs` uses, so "the CLI and the HTTP API produce the same body" is asserted
  against one set of sources rather than two.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias O11yProxy.CLI

  describe "argument handling" do
    test "--help and --version print to stdout and exit 0" do
      assert {output, 0} = run(["--help"])
      assert output =~ "USAGE"
      assert output =~ "o11y-proxy query"

      assert {output, 0} = run(["--version"])
      assert output =~ "o11y-proxy"
    end

    test "no arguments asks for the server rather than running a command" do
      assert CLI.main([]) == :serve
      assert CLI.main(["serve"]) == :serve
    end

    test "a usage error goes to stderr and exits 1, leaving stdout clean" do
      assert {stdout, stderr, 1} = run_split(["query", "--source", "x"])
      assert stdout == ""
      assert stderr =~ "o11y-proxy: query requires --signal"
    end

    test "an unknown command exits 1" do
      assert {stderr, 1} = run_stderr(["quesry"])
      assert stderr =~ "unknown command: quesry"
    end
  end

  describe "commands against real sources" do
    test "sources lists what's configured" do
      name = start_fake_source!()
      assert {output, 0} = run(["sources"])

      assert %{"sources" => sources} = Jason.decode!(output)
      assert Enum.any?(sources, &(&1["name"] == name))
    end

    test "health reports per-source reachability" do
      name = start_fake_source!()
      assert {output, 0} = run(["health"])
      assert %{"sources" => statuses} = Jason.decode!(output)
      assert statuses[name]["status"] == "ok"
    end

    test "schema returns the field map for one source" do
      name = start_fake_source!()
      assert {output, 0} = run(["schema", name])
      assert %{"fields" => _} = Jason.decode!(output)
    end

    test "schema for an unknown source exits 1 with a structured error on stderr" do
      assert {stdout, stderr, 1} = run_split(["schema", "nope"])
      assert stdout == ""
      assert %{"error" => "not_found", "message" => message} = Jason.decode!(stderr)
      assert message =~ "nope"
    end

    test "query runs end-to-end and prints the same envelope the HTTP endpoint sends" do
      name = start_fake_source!()

      assert {output, 0} =
               run(~w(query --source #{name} --signal logs --from now-1h --to now --mode sample))

      assert %{"data" => data, "meta" => meta, "errors" => []} = Jason.decode!(output)
      assert length(data) == 2
      assert Enum.all?(data, &(&1["source"] == name))
      assert meta["sources_queried"] == [name]
      assert meta["native_queries"][name] =~ "SELECT"
    end

    test "--filter reaches the backend as a canonical filter" do
      name = start_fake_source!()

      assert {output, 0} =
               run(~w(query --source #{name} --signal logs --from now-1h --to now
                      --filter severity=error))

      assert %{"meta" => meta} = Jason.decode!(output)
      assert meta["native_queries"][name] =~ "severity"
    end

    test "an unparseable filter fails before anything is queried" do
      name = start_fake_source!()

      assert {stdout, stderr, 1} =
               run_split(~w(query --source #{name} --signal logs --from now-1h --to now
                            --filter nonsense))

      assert stdout == ""
      assert stderr =~ "has no operator"
    end

    test "query against an unknown source exits 1" do
      assert {stderr, 1} =
               run_stderr(~w(query --source nope --signal logs --from now-1h --to now))

      assert %{"error" => "not_found"} = Jason.decode!(stderr)
    end

    # The headline exit-code rule: a backend that failed is a partial answer, not a failed
    # request. `errors[]` is populated, stdout still carries a usable envelope, exit is 0 —
    # exactly the HTTP 200 the same result gets.
    test "a failing source is exit 0 with the failure in errors[]" do
      name = start_fake_source!(fail: true)

      assert {output, 0} =
               run(~w(query --source #{name} --signal logs --from now-1h --to now))

      assert %{"data" => [], "errors" => [error]} = Jason.decode!(output)
      assert error["source"] == name
    end

    test "context correlates a trace across sources" do
      logs = start_fake_source!(signal: :logs)
      traces = start_fake_source!(signal: :traces)

      assert {output, 0} = run(~w(context --trace-id abc123))

      assert %{"trace" => trace, "logs" => log_records, "errors" => []} = Jason.decode!(output)
      assert Enum.all?(trace, &(&1["source"] == traces))
      assert Enum.all?(log_records, &(&1["source"] == logs))
    end

    test "context redacts sensitive attributes, same as over HTTP" do
      _errors = start_fake_errors_source!(known_id: "ERR-1")

      assert {output, 0} = run(~w(context --error-id ERR-1))
      assert %{"error" => error} = Jason.decode!(output)
      assert error["attributes"]["authorization"] == "[REDACTED]"
    end

    test "an ambiguous context request is rejected by the core, exit 1" do
      assert {stderr, 1} = run_stderr(~w(context --trace-id abc --error-id ERR-1))
      assert %{"error" => "invalid_query", "message" => message} = Jason.decode!(stderr)
      assert message =~ "exactly one"
    end
  end

  describe "output" do
    test "the default is compact JSON on one line, so `| jq` gets a clean stream" do
      _name = start_fake_source!()
      assert {output, 0} = run(["sources"])
      assert length(String.split(String.trim(output), "\n")) == 1
    end

    test "--pretty indents it" do
      _name = start_fake_source!()
      assert {output, 0} = run(["sources", "--pretty"])
      assert output =~ ~r/\{\n\s+"sources"/
    end
  end

  # The anti-drift assertion the whole design is for. Both transports enter through
  # O11yProxy.Remote.handle/1, so for the same request the CLI's stdout and the HTTP
  # response body must agree — not merely "both look reasonable". Compared against a real
  # response from the router rather than against Remote directly, which would only be
  # asserting that one function equals itself.
  test "CLI stdout matches the HTTP response body for the same request" do
    for {argv, method, path, body} <- [
          {~w(query --source SOURCE --signal logs --from now-1h --to now --mode sample), :post,
           "/v1/query",
           %{
             "sources" => ["SOURCE"],
             "signal" => "logs",
             "from" => "now-1h",
             "to" => "now",
             "mode" => "sample"
           }},
          {~w(context --trace-id abc123), :post, "/v1/context", %{"trace_id" => "abc123"}},
          {~w(sources), :get, "/v1/sources", nil},
          {~w(health), :get, "/healthz", nil}
        ] do
      name = start_fake_source!()
      argv = Enum.map(argv, &String.replace(&1, "SOURCE", name))
      body = body && substitute(body, name)

      assert {cli_output, 0} = run(argv)
      http_body = http(method, path, body)

      assert normalize(Jason.decode!(cli_output)) == normalize(http_body),
             "#{Enum.join(argv, " ")} disagreed with #{method} #{path}"
    end
  end

  defp substitute(body, name) do
    case body do
      %{"sources" => ["SOURCE"]} -> %{body | "sources" => [name]}
      other -> other
    end
  end

  defp http(:get, path, _body) do
    Plug.Test.conn(:get, path)
    |> O11yProxy.Router.call(O11yProxy.Router.init([]))
    |> then(&Jason.decode!(&1.resp_body))
  end

  defp http(:post, path, body) do
    Plug.Test.conn(:post, path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> O11yProxy.Router.call(O11yProxy.Router.init([]))
    |> then(&Jason.decode!(&1.resp_body))
  end

  # Two runs against a live backend are two different moments, and FakeBackend stamps
  # `DateTime.utc_now()` on every record it returns. Wall-clock is the *only* thing
  # allowed to differ; every other byte has to match.
  defp normalize(body) when is_map(body) do
    body
    |> Map.new(fn
      {"elapsed_ms", _} -> {"elapsed_ms", :wall_clock}
      {"timestamp", _} -> {"timestamp", :wall_clock}
      {k, v} -> {k, normalize(v)}
    end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other

  # capture_io/2 hands back only what was written, so main/1's exit status is passed out
  # through the mailbox. Nesting the two captures is what lets a test assert that stdout
  # stayed empty while the error went to stderr — the property that keeps `| jq` clean.
  defp run(argv),
    do: run_split(argv) |> then(fn {stdout, _stderr, status} -> {stdout, status} end)

  defp run_stderr(argv),
    do: run_split(argv) |> then(fn {_stdout, stderr, status} -> {stderr, status} end)

  defp run_split(argv) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        send(parent, {:captured, capture_io(fn -> send(parent, {:status, CLI.main(argv)}) end)})
      end)

    receive do
      {:captured, stdout} ->
        receive do
          {:status, status} -> {stdout, stderr, status}
        after
          0 -> flunk("main/1 did not return")
        end
    after
      0 -> flunk("stdout was not captured")
    end
  end

  defp start_fake_source!(opts \\ []) do
    name = Keyword.get(opts, :name, "cli_test_fake_#{System.unique_integer([:positive])}")

    start_source!(%O11yProxy.Config.Source{
      name: name,
      backend: O11yProxy.Test.FakeBackend,
      backend_name: "fake",
      signal: Keyword.get(opts, :signal, :logs),
      opts: %{
        table: "fake_logs",
        allow_raw: false,
        fail: Keyword.get(opts, :fail, false),
        trace_id: Keyword.get(opts, :trace_id, "abc123")
      }
    })
  end

  defp start_fake_errors_source!(opts) do
    name = Keyword.get(opts, :name, "cli_test_errors_#{System.unique_integer([:positive])}")

    start_source!(%O11yProxy.Config.Source{
      name: name,
      backend: O11yProxy.Test.FakeErrorsBackend,
      backend_name: "fake_errors",
      signal: :errors,
      opts: %{
        known_id: Keyword.get(opts, :known_id, "ERR-1"),
        trace_id: Keyword.get(opts, :trace_id, "abc123"),
        fail: Keyword.get(opts, :fail, false)
      }
    })
  end

  defp start_source!(source) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        O11yProxy.Sources.Supervisor,
        {O11yProxy.Sources.Server, source}
      )

    on_exit(fn -> DynamicSupervisor.terminate_child(O11yProxy.Sources.Supervisor, pid) end)
    source.name
  end
end
