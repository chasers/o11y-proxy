defmodule O11yProxy.RouterOIDCTest do
  @moduledoc """
  The router end to end under `server.auth: oidc`: real tokens from a local fake issuer,
  real fake sources, and the policy layer in between. These pin the behaviour the docs
  promise — refusals are 401/403 with an actionable message, injected filters are visible
  in `meta.native_queries`, and `/v1/context` reports a constrained source in `errors[]`
  rather than failing the whole bundle.

  `async: false` because auth mode, issuer config and policies are application env, and
  the key cache is one named process.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias O11yProxy.Policy
  alias O11yProxy.Policy.Constraint
  alias O11yProxy.Test.OIDC

  @opts O11yProxy.Router.init([])

  setup_all do
    %{key: OIDC.key("k1")}
  end

  setup %{key: key} do
    OIDC.start_keys(OIDC.start_issuer([key]))
    previous = Application.get_env(:o11y_proxy, :auth)
    Application.put_env(:o11y_proxy, :auth, :oidc)
    Application.put_env(:o11y_proxy, :oidc, OIDC.config())

    on_exit(fn ->
      Application.put_env(:o11y_proxy, :auth, previous || :none)
      Application.delete_env(:o11y_proxy, :oidc)
      Application.delete_env(:o11y_proxy, :policies)
    end)

    logs = start_source!("oidc_logs", O11yProxy.Test.FakeBackend, :logs)
    other = start_source!("oidc_other", O11yProxy.Test.FakeBackend, :logs)
    errors = start_source!("oidc_errors", O11yProxy.Test.FakeErrorsBackend, :errors)

    policies = %{
      "support" => %Policy{
        name: "support",
        sources: [logs, errors],
        max_limit: 20,
        constraints: [
          %Constraint{
            sources: [logs],
            field: "project",
            require: true,
            allowed: [],
            allowed_claim: "o11y.projects"
          }
        ]
      },
      "tenant" => %Policy{
        name: "tenant",
        sources: [logs],
        constraints: [
          %Constraint{field: "project", inject: true, allowed: [], allowed_claim: "o11y.projects"}
        ]
      },
      "scoped_errors" => %Policy{
        name: "scoped_errors",
        sources: [errors],
        constraints: [%Constraint{field: "project", inject: true, allowed: ["p1"]}]
      },
      "short" => %Policy{
        name: "short",
        sources: [logs],
        max_lookback: "1h",
        max_lookback_seconds: 3600,
        max_limit: 5
      },
      "sre" => %Policy{name: "sre", sources: :all, raw: :allow}
    }

    Application.put_env(:o11y_proxy, :policies, policies)
    %{logs: logs, other: other, errors: errors}
  end

  defp token(key, role, projects \\ ["p1", "p2"]) do
    OIDC.token(key, OIDC.claims(%{"o11y" => %{"role" => role, "projects" => projects}}))
  end

  defp request(method, path, token, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn =
      if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    conn = O11yProxy.Router.call(conn, @opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp query_body(source, extra \\ %{}) do
    Map.merge(
      %{
        "sources" => [source],
        "signal" => "logs",
        "from" => "now-1h",
        "to" => "now",
        "mode" => "sample"
      },
      extra
    )
  end

  test "data routes need a token; /healthz and /openapi.json do not", %{logs: logs} do
    assert {401, %{"error" => "unauthorized"}} =
             request(:post, "/v1/query", nil, query_body(logs))

    assert {401, _} = request(:get, "/v1/sources", nil)
    assert {200, _} = request(:get, "/healthz", nil)
    assert {200, %{"openapi" => _}} = request(:get, "/openapi.json", nil)
  end

  test "a token for another audience is a 401", %{key: key, logs: logs} do
    token = OIDC.token(key, OIDC.claims(%{"aud" => "someone-else", "o11y" => %{"role" => "sre"}}))
    assert {401, %{"message" => message}} = request(:post, "/v1/query", token, query_body(logs))
    assert message =~ "audience"
  end

  test "a role with no policy is a 403 before any route runs", %{key: key} do
    assert {403, %{"error" => "forbidden"}} = request(:get, "/v1/sources", token(key, "intern"))
  end

  test "/v1/sources lists only the sources the policy permits",
       %{key: key, logs: logs, other: other, errors: errors} do
    {200, %{"sources" => sources}} = request(:get, "/v1/sources", token(key, "support"))
    names = Enum.map(sources, & &1["name"])

    assert logs in names
    assert errors in names
    refute other in names
  end

  test "schema and query on a source outside the policy are 403", %{key: key, other: other} do
    token = token(key, "support")

    assert {403, %{"error" => "forbidden"}} = request(:get, "/v1/sources/#{other}/schema", token)

    assert {403, %{"error" => "forbidden", "message" => message}} =
             request(:post, "/v1/query", token, query_body(other))

    assert message =~ "does not permit source"
  end

  test "a required filter that is missing is a 403 naming the field and the caller's values",
       %{key: key, logs: logs} do
    assert {403, %{"message" => message}} =
             request(:post, "/v1/query", token(key, "support"), query_body(logs))

    assert message =~ "requires a filter on project"
    assert message =~ ~s("p1", "p2")
  end

  test "a required filter within the caller's values runs", %{key: key, logs: logs} do
    body =
      query_body(logs, %{"filters" => [%{"field" => "project", "op" => "eq", "value" => "p2"}]})

    assert {200, %{"errors" => [], "data" => [_ | _]}} =
             request(:post, "/v1/query", token(key, "support"), body)
  end

  test "a value outside the caller's claim is a 403", %{key: key, logs: logs} do
    body =
      query_body(logs, %{"filters" => [%{"field" => "project", "op" => "eq", "value" => "p9"}]})

    assert {403, %{"message" => message}} =
             request(:post, "/v1/query", token(key, "support"), body)

    assert message =~ ~s(value "p9" is not permitted)
  end

  test "an injected filter is applied and visible in meta.native_queries", %{key: key, logs: logs} do
    {200, %{"meta" => meta}} = request(:post, "/v1/query", token(key, "tenant"), query_body(logs))
    assert meta["native_queries"][logs] =~ "project IN"

    {200, %{"meta" => meta}} =
      request(:post, "/v1/query", token(key, "tenant", ["only"]), query_body(logs))

    assert meta["native_queries"][logs] =~ "project ="
  end

  test "raw is refused under a policy that denies it", %{key: key, logs: logs} do
    body = query_body(logs, %{"raw" => "SELECT 1"})

    assert {403, %{"message" => message}} =
             request(:post, "/v1/query", token(key, "tenant"), body)

    assert message =~ "raw"
  end

  test "an omitted limit is kept inside max_limit; an explicit one over it is refused",
       %{key: key, errors: errors} do
    token = token(key, "support")
    body = %{"sources" => [errors], "signal" => "errors", "from" => "now-1h", "to" => "now"}

    assert {200, _} = request(:post, "/v1/query", token, body)

    assert {403, %{"message" => message}} =
             request(:post, "/v1/query", token, Map.put(body, "limit", 21))

    assert message =~ "max_limit of 20"
  end

  test "an unrestricted role is unaffected", %{key: key, other: other} do
    assert {200, %{"errors" => []}} =
             request(:post, "/v1/query", token(key, "sre"), query_body(other))
  end

  describe "/v1/context" do
    test "never queries a source outside the policy, and reports a constrained one in errors[]",
         %{key: key, logs: logs, other: other} do
      body = %{"service" => "checkout-api", "from" => "now-1h", "to" => "now"}

      {200, %{"errors" => errors, "meta" => meta}} =
        request(:post, "/v1/context", token(key, "support"), body)

      refute other in meta["sources_queried"]
      assert logs in meta["sources_queried"]

      assert %{"code" => "forbidden", "message" => message} =
               Enum.find(errors, &(&1["source"] == logs))

      assert message =~ "requires a filter on project"
    end

    test "context keeps the window and limit it picks inside the policy's caps",
         %{key: key, logs: logs} do
      {200, %{"errors" => [], "meta" => meta}} =
        request(:post, "/v1/context", token(key, "short"), %{"trace_id" => "abc123"})

      assert meta["sources_queried"] == [logs]
    end

    test "a caller-chosen window past max_lookback is refused per source", %{key: key, logs: logs} do
      body = %{"service" => "checkout-api", "from" => "now-2d", "to" => "now"}

      {200, %{"errors" => [%{"source" => ^logs, "code" => "forbidden"}]}} =
        request(:post, "/v1/context", token(key, "short"), body)
    end

    test "an injected constraint lets context query the source", %{key: key, logs: logs} do
      body = %{"service" => "checkout-api", "from" => "now-1h", "to" => "now"}

      {200, %{"errors" => [], "meta" => meta}} =
        request(:post, "/v1/context", token(key, "tenant"), body)

      assert meta["native_queries"][logs] =~ "project IN"
    end

    test "a lookup by error ID on a permitted, unconstrained source works",
         %{key: key, errors: errors} do
      {200, %{"error" => error}} =
        request(:post, "/v1/context", token(key, "support"), %{"error_id" => "ERR-1"})

      assert error["source"] == errors
    end

    test "a lookup by error ID on a constrained source is refused in errors[], not answered",
         %{key: key, errors: errors} do
      {200, %{"error" => nil, "errors" => [refusal]}} =
        request(:post, "/v1/context", token(key, "scoped_errors"), %{"error_id" => "ERR-1"})

      assert %{"source" => ^errors, "code" => "forbidden", "message" => message} = refusal
      assert message =~ "cannot be scoped by project"
    end
  end

  defp start_source!(prefix, backend, signal) do
    name = "#{prefix}_#{System.unique_integer([:positive])}"

    opts =
      case backend do
        O11yProxy.Test.FakeBackend ->
          %{table: "fake_logs", allow_raw: false, fail: false, trace_id: "abc123"}

        O11yProxy.Test.FakeErrorsBackend ->
          %{known_id: "ERR-1", trace_id: "abc123", fail: false}
      end

    source = %O11yProxy.Config.Source{
      name: name,
      backend: backend,
      backend_name: "fake",
      signal: signal,
      opts: opts
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
