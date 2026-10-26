defmodule O11yProxy.Plugs.AuthTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias O11yProxy.Plugs.Auth

  setup do
    previous = {Application.get_env(:o11y_proxy, :auth), System.get_env("O11Y_PROXY_TOKEN")}
    Application.put_env(:o11y_proxy, :auth, :token)
    System.put_env("O11Y_PROXY_TOKEN", "s3cret")

    on_exit(fn ->
      {auth, token} = previous
      Application.put_env(:o11y_proxy, :auth, auth || :none)

      if token,
        do: System.put_env("O11Y_PROXY_TOKEN", token),
        else: System.delete_env("O11Y_PROXY_TOKEN")
    end)
  end

  defp call(path, headers \\ []) do
    headers
    |> Enum.reduce(conn(:get, path), fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> Auth.call(Auth.init([]))
  end

  test "/healthz and /openapi.json are open without credentials" do
    for path <- ["/healthz", "/openapi.json"] do
      conn = call(path)
      refute conn.halted
      refute Map.has_key?(conn.assigns, :caller)
    end
  end

  test "a data route without credentials is a 401 with a Bearer challenge" do
    conn = call("/v1/sources")

    assert conn.halted
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    assert %{"error" => "unauthorized"} = Jason.decode!(conn.resp_body)
  end

  test "valid credentials assign the caller and continue" do
    conn = call("/v1/sources", [{"authorization", "Bearer s3cret"}])
    refute conn.halted
    assert %O11yProxy.Caller{id: "local"} = conn.assigns.caller
  end

  test "/metrics is not open" do
    assert call("/metrics").status == 401
  end

  defmodule Refuses do
    @behaviour O11yProxy.Auth
    @impl true
    def authenticate([{"x-mode", "forbidden"}]), do: {:error, {:forbidden, "no grant"}}
    def authenticate(_headers), do: {:error, {:unavailable, "keys not loaded"}}
  end

  describe "with an authenticator that refuses" do
    setup do
      Application.put_env(:o11y_proxy, :authenticators, %{token: Refuses})
      on_exit(fn -> Application.delete_env(:o11y_proxy, :authenticators) end)
    end

    test "forbidden is a 403" do
      conn = call("/v1/sources", [{"x-mode", "forbidden"}])
      assert conn.status == 403
      assert %{"error" => "forbidden", "message" => "no grant"} = Jason.decode!(conn.resp_body)
    end

    test "unavailable is a 503 with retry-after" do
      conn = call("/v1/sources")
      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["5"]
      assert %{"error" => "auth_unavailable"} = Jason.decode!(conn.resp_body)
    end
  end
end
