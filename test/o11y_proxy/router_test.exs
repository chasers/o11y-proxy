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

  test "POST /v1/query rejects more than one source — fan-out is Phase 5" do
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
    assert length(data) == 2
    assert Enum.all?(data, &(&1["source"] == name))
    assert meta["sources_queried"] == [name]
    assert meta["native_queries"][name] =~ "SELECT"
  end

  test "POST /v1/context is still a structured not_implemented (correlation is Phase 5)" do
    conn = post_json(:post, "/v1/context", %{"trace_id" => "abc"})
    assert conn.status == 501
    assert %{"error" => "not_implemented"} = Jason.decode!(conn.resp_body)
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

  defp start_fake_source!(name \\ "router_test_fake_#{System.unique_integer([:positive])}") do
    source = %O11yProxy.Config.Source{
      name: name,
      backend: O11yProxy.Test.FakeBackend,
      backend_name: "fake",
      signal: :logs,
      opts: %{table: "fake_logs", allow_raw: false}
    }

    {:ok, pid} =
      DynamicSupervisor.start_child(
        O11yProxy.Sources.Supervisor,
        {O11yProxy.Sources.Server, source}
      )

    on_exit(fn -> DynamicSupervisor.terminate_child(O11yProxy.Sources.Supervisor, pid) end)
    name
  end
end
