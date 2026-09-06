defmodule O11yProxy.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @opts O11yProxy.Router.init([])

  test "GET /v1/sources returns the configured sources (none yet — Phase 1 skeleton)" do
    conn = conn(:get, "/v1/sources") |> O11yProxy.Router.call(@opts)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"sources" => []}
  end

  test "GET /healthz returns per-source reachability" do
    conn = conn(:get, "/healthz") |> O11yProxy.Router.call(@opts)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"sources" => %{}}
  end

  test "GET /v1/sources/:name/schema 404s for an unknown source" do
    conn = conn(:get, "/v1/sources/nope/schema") |> O11yProxy.Router.call(@opts)
    assert conn.status == 404
    assert %{"error" => "not_found"} = Jason.decode!(conn.resp_body)
  end

  test "GET /openapi.json serves the spec" do
    conn = conn(:get, "/openapi.json") |> O11yProxy.Router.call(@opts)
    assert conn.status == 200
    assert %{"openapi" => "3.1.0"} = Jason.decode!(conn.resp_body)
  end

  test "GET /metrics serves Prometheus exposition text" do
    # The prometheus_core reporter aggregates on its own interval, so right after boot
    # the body can legitimately still be empty — assert the plumbing, not a sample.
    conn = conn(:get, "/metrics") |> O11yProxy.Router.call(@opts)
    assert conn.status == 200

    assert {"content-type", "text/plain" <> _} =
             List.keyfind(conn.resp_headers, "content-type", 0)

    assert is_binary(conn.resp_body)
  end

  test "POST /v1/query rejects a request missing required fields" do
    conn = post_json(:post, "/v1/query", %{})
    assert conn.status == 400
    assert %{"error" => "invalid_query"} = Jason.decode!(conn.resp_body)
  end

  test "POST /v1/query 404s for an unknown source" do
    conn =
      post_json(:post, "/v1/query", %{
        "sources" => ["nope"],
        "signal" => "logs",
        "from" => "now-1h",
        "to" => "now"
      })

    assert conn.status == 404
    assert %{"error" => "not_found"} = Jason.decode!(conn.resp_body)
  end

  test "POST /v1/query rejects more than one source — query fan-out is not built" do
    conn =
      post_json(:post, "/v1/query", %{
        "sources" => ["a", "b"],
        "signal" => "logs",
        "from" => "now-1h",
        "to" => "now"
      })

    assert conn.status == 400
    assert %{"error" => "unsupported"} = Jason.decode!(conn.resp_body)
  end

  test "POST /v1/query runs a real query end-to-end against a registered source" do
    name = start_fake_source!()

    conn =
      post_json(:post, "/v1/query", %{
        "sources" => [name],
        "signal" => "logs",
        "from" => "now-1h",
        "to" => "now",
        "mode" => "sample"
      })

    assert conn.status == 200
    assert %{"data" => data, "meta" => meta, "errors" => []} = Jason.decode!(conn.resp_body)
    assert [_, _] = data
    assert Enum.all?(data, &(&1["source"] == name))
    assert meta["sources_queried"] == [name]
    assert meta["native_queries"][name] =~ "SELECT"
  end

  describe "POST /v1/context" do
    test "requires exactly one entry kind" do
      conn = post_json(:post, "/v1/context", %{})
      assert conn.status == 400
      assert %{"error" => "invalid_query", "message" => message} = Jason.decode!(conn.resp_body)
      assert message =~ "required"
    end

    test "rejects more than one entry kind" do
      conn = post_json(:post, "/v1/context", %{"trace_id" => "abc", "error_id" => "ERR-1"})
      assert conn.status == 400
      assert %{"message" => message} = Jason.decode!(conn.resp_body)
      assert message =~ "exactly one"
    end

    test "fans a trace_id out across every configured source, bucketed by signal" do
      logs = start_fake_source!(signal: :logs)
      traces = start_fake_source!(signal: :traces)

      conn = post_json(:post, "/v1/context", %{"trace_id" => "abc123"})
      assert conn.status == 200

      assert %{"trace" => trace, "logs" => log_records, "meta" => meta, "errors" => []} =
               Jason.decode!(conn.resp_body)

      assert [_ | _] = trace
      assert [_ | _] = log_records
      assert Enum.all?(trace, &(&1["source"] == traces))
      assert Enum.all?(log_records, &(&1["source"] == logs))
      assert Enum.sort(meta["sources_queried"]) == Enum.sort([logs, traces])
      assert meta["native_queries"][logs] =~ "SELECT"
    end

    test "a failing source lands in errors while healthy sources still return data" do
      healthy = start_fake_source!(signal: :logs)
      broken = start_fake_source!(signal: :traces, fail: true)

      conn = post_json(:post, "/v1/context", %{"trace_id" => "abc123"})
      assert conn.status == 200

      assert %{"logs" => log_records, "trace" => [], "errors" => [error]} =
               Jason.decode!(conn.resp_body)

      assert [_ | _] = log_records
      assert error["source"] == broken
      assert error["code"] == "internal"
      assert Enum.all?(log_records, &(&1["source"] == healthy))
    end

    test "error_id resolves through fetch_by_id/2 and correlates on the error's trace_id" do
      _errors = start_fake_errors_source!(known_id: "ERR-1", trace_id: "abc123")
      logs = start_fake_source!(signal: :logs)

      conn = post_json(:post, "/v1/context", %{"error_id" => "ERR-1"})
      assert conn.status == 200

      assert %{"error" => error, "logs" => log_records} = Jason.decode!(conn.resp_body)
      assert error["body"] =~ "everything is on fire"
      assert error["trace_id"] == "abc123"
      assert [_ | _] = log_records
      assert Enum.all?(log_records, &(&1["source"] == logs))
    end

    test "an unknown error_id gives error: null, not an errors entry" do
      _errors = start_fake_errors_source!(known_id: "ERR-1")

      conn = post_json(:post, "/v1/context", %{"error_id" => "NOPE"})
      assert conn.status == 200
      assert %{"error" => nil, "errors" => []} = Jason.decode!(conn.resp_body)
    end

    test "redacts sensitive attributes in the bundled error" do
      _errors = start_fake_errors_source!(known_id: "ERR-1")

      conn = post_json(:post, "/v1/context", %{"error_id" => "ERR-1"})
      assert %{"error" => error} = Jason.decode!(conn.resp_body)
      assert error["attributes"]["authorization"] == "[REDACTED]"
    end

    test "{from, to, service} correlates without a trace anchor" do
      logs = start_fake_source!(signal: :logs)

      conn =
        post_json(:post, "/v1/context", %{
          "from" => "now-1h",
          "to" => "now",
          "service" => "fake-service"
        })

      assert conn.status == 200
      assert %{"logs" => log_records, "meta" => meta} = Jason.decode!(conn.resp_body)
      assert [_ | _] = log_records
      assert meta["sources_queried"] == [logs]
    end
  end

  describe "circuit breaker" do
    setup do
      previous = Application.get_env(:o11y_proxy, :breaker)
      Application.put_env(:o11y_proxy, :breaker, threshold: 2, backoff_ms: 10_000)
      on_exit(fn -> restore_env(:breaker, previous) end)
      :ok
    end

    test "opens after consecutive failures and fails fast with a retry hint" do
      name = start_fake_source!(signal: :logs, fail: true)

      # Two failures trip the breaker (threshold: 2 above).
      for _ <- 1..2 do
        assert {:error, {:fake_unreachable, _}} =
                 O11yProxy.Sources.run_query(name, logs_query(), 1_000)
      end

      assert {:error, {:circuit_open, retry_after_ms}} =
               O11yProxy.Sources.run_query(name, logs_query(), 1_000)

      assert retry_after_ms > 0
    end

    test "an open breaker surfaces as an unreachable error with retry_after_ms in the envelope" do
      name = start_fake_source!(signal: :logs, fail: true)

      for _ <- 1..2, do: O11yProxy.Sources.run_query(name, logs_query(), 1_000)

      conn =
        post_json(:post, "/v1/query", %{
          "sources" => [name],
          "signal" => "logs",
          "from" => "now-1h",
          "to" => "now",
          "mode" => "sample"
        })

      assert conn.status == 200
      assert %{"errors" => [error]} = Jason.decode!(conn.resp_body)
      assert error["code"] == "unreachable"
      assert error["retry_after_ms"] > 0
      assert error["message"] =~ "circuit breaker open"
    end

    test "a compile error never trips the breaker — the backend was never contacted" do
      name = start_fake_source!(signal: :logs)

      # FakeBackend declares no :regex support, so this fails in compile/2, not execute/2.
      bad = %{
        logs_query()
        | filters: [%O11yProxy.Query.Filter{field: "body", op: :regex, value: "x"}]
      }

      for _ <- 1..5 do
        assert {:error, {:unsupported_operator, :regex}} =
                 O11yProxy.Sources.run_query(name, bad, 1_000)
      end

      # Still healthy: a client-side dialect mismatch is not a backend outage. This is the
      # exact path /v1/context's {from,to,service} fan-out takes against Sentry.
      assert O11yProxy.Sources.breaker_status(name) == :closed
      assert {:ok, _} = O11yProxy.Sources.run_query(name, logs_query(), 1_000)
    end

    test "repeated {from,to,service} context calls don't wedge a source that can't express the filter" do
      name = start_fake_source!(signal: :logs)

      for _ <- 1..5 do
        conn =
          post_json(:post, "/v1/context", %{
            "from" => "now-1h",
            "to" => "now",
            "service" => "fake-service"
          })

        assert conn.status == 200
      end

      assert O11yProxy.Sources.breaker_status(name) == :closed
    end

    test "a success resets the failure count, so the breaker only trips on consecutive failures" do
      name = start_fake_source!(signal: :logs)

      assert {:ok, _} = O11yProxy.Sources.run_query(name, logs_query(), 1_000)
      assert {:ok, _} = O11yProxy.Sources.run_query(name, logs_query(), 1_000)
      assert {:ok, _} = O11yProxy.Sources.run_query(name, logs_query(), 1_000)
    end
  end

  test "unknown routes 404 with a structured body" do
    conn = conn(:get, "/nope") |> O11yProxy.Router.call(@opts)
    assert conn.status == 404
    assert %{"error" => "not_found"} = Jason.decode!(conn.resp_body)
  end

  defp post_json(:post, path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> O11yProxy.Router.call(@opts)
  end

  defp start_fake_source!(opts \\ []) do
    name = Keyword.get(opts, :name, "router_test_fake_#{System.unique_integer([:positive])}")

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
    name = Keyword.get(opts, :name, "router_test_errors_#{System.unique_integer([:positive])}")

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

  defp logs_query do
    %O11yProxy.Query{
      signal: :logs,
      from: DateTime.add(DateTime.utc_now(), -3600, :second),
      to: DateTime.utc_now(),
      mode: :sample,
      limit: 10
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:o11y_proxy, key)
  defp restore_env(key, value), do: Application.put_env(:o11y_proxy, key, value)
end
