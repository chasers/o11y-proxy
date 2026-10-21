defmodule O11yProxy.AuthTest do
  use ExUnit.Case, async: false

  alias O11yProxy.{Auth, Caller}

  describe "bearer/1" do
    test "reads the token, matching the scheme case-insensitively" do
      assert {:ok, "abc"} = Auth.bearer([{"authorization", "Bearer abc"}])
      assert {:ok, "abc"} = Auth.bearer([{"authorization", "bearer abc"}])
    end

    test "refuses a missing header, another scheme, an empty token, or two headers" do
      for headers <- [
            [],
            [{"authorization", "Basic abc"}],
            [{"authorization", "Bearer "}],
            [{"authorization", "Bearer"}],
            [{"authorization", "Bearer a"}, {"authorization", "Bearer b"}]
          ] do
        assert {:error, {:unauthorized, _}} = Auth.bearer(headers)
      end
    end
  end

  describe "impl/1" do
    test "maps each mode to its built-in implementation" do
      assert Auth.impl(:none) == Auth.None
      assert Auth.impl(:token) == Auth.Token
      assert Auth.impl(:oidc) == Auth.OIDC
    end

    test "honours an embedder's override for a mode" do
      Application.put_env(:o11y_proxy, :authenticators, %{oidc: __MODULE__})
      on_exit(fn -> Application.delete_env(:o11y_proxy, :authenticators) end)

      assert Auth.impl(:oidc) == __MODULE__
      assert Auth.impl(:token) == Auth.Token
    end
  end

  describe "Auth.None" do
    test "is always the local, unrestricted caller" do
      assert {:ok, %Caller{id: "local", policy: nil}} = Auth.None.authenticate([])
    end
  end

  describe "Auth.Token" do
    setup do
      previous = System.get_env("O11Y_PROXY_TOKEN")
      on_exit(fn -> restore("O11Y_PROXY_TOKEN", previous) end)
    end

    defp restore(var, nil), do: System.delete_env(var)
    defp restore(var, value), do: System.put_env(var, value)

    test "accepts the configured token" do
      System.put_env("O11Y_PROXY_TOKEN", "s3cret")

      assert {:ok, %Caller{id: "local", policy: nil}} =
               Auth.Token.authenticate([{"authorization", "Bearer s3cret"}])
    end

    test "refuses a wrong token" do
      System.put_env("O11Y_PROXY_TOKEN", "s3cret")

      assert {:error, {:unauthorized, _}} =
               Auth.Token.authenticate([{"authorization", "Bearer nope"}])
    end

    test "refuses everything when O11Y_PROXY_TOKEN is unset" do
      System.delete_env("O11Y_PROXY_TOKEN")

      assert {:error, {:unauthorized, _}} =
               Auth.Token.authenticate([{"authorization", "Bearer "}])

      assert {:error, {:unauthorized, _}} =
               Auth.Token.authenticate([{"authorization", "Bearer x"}])
    end
  end
end
