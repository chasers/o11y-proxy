defmodule O11yProxy.RemoteTest do
  use ExUnit.Case, async: true

  alias O11yProxy.{Config, Remote}

  describe "node_name/1" do
    # Derived from the port so both sides compute the same name with no handshake file,
    # and so two daemons with different configs never collide on one name.
    test "derives from the port, so two daemons don't collide" do
      assert Remote.node_name(config(4000)) == :"o11y_proxy_4000@127.0.0.1"
      assert Remote.node_name(config(4001)) == :"o11y_proxy_4001@127.0.0.1"
      refute Remote.node_name(config(4000)) == Remote.node_name(config(4001))
    end

    test "is always loopback — distribution must never be reachable off-box" do
      assert Remote.node_name(config(4000)) |> Atom.to_string() |> String.ends_with?("@127.0.0.1")
    end
  end

  describe "protocol_version/0" do
    test "is a protocol integer, not the app version" do
      assert is_integer(Remote.protocol_version())
      assert Remote.protocol_version() > 0
    end
  end

  describe "handle/1" do
    test "an unrecognized request is a structured error, not a crash" do
      assert {:error, %{error: "invalid_query"}} = Remote.handle(%{"command" => "nope"})
      assert {:error, %{error: "invalid_query"}} = Remote.handle(%{})
    end

    test "a malformed query request names what was wrong" do
      assert {:error, %{error: "invalid_query"}} =
               Remote.handle(%{"command" => "query", "request" => %{}})
    end

    test "an unknown source is not_found" do
      assert {:error, %{error: "not_found"}} =
               Remote.handle(%{"command" => "schema", "request" => %{"source" => "nope"}})
    end

    test "fan-out across several sources is still unsupported, and says so" do
      assert {:error, %{error: "unsupported"}} =
               Remote.handle(%{
                 "command" => "query",
                 "request" => %{
                   "sources" => ["a", "b"],
                   "signal" => "logs",
                   "from" => "now-1h",
                   "to" => "now"
                 }
               })
    end
  end

  defp config(port) do
    %Config{
      server: %{port: port, auth: :none, distribution: true},
      defaults: %{limit: 50, max_window: "7d", timeout: "30s", max_bytes: 64_000},
      sources: []
    }
  end
end
