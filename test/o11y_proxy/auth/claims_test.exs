defmodule O11yProxy.Auth.ClaimsTest do
  use ExUnit.Case, async: true

  alias O11yProxy.Auth.Claims

  describe "get/2" do
    test "reads a top-level claim" do
      assert {:ok, "user-1"} = Claims.get(%{"sub" => "user-1"}, "sub")
    end

    test "walks nested maps by dotted path" do
      assert {:ok, "support"} = Claims.get(%{"o11y" => %{"role" => "support"}}, "o11y.role")
    end

    test "matches a claim name that itself contains dots before splitting" do
      claims = %{"https://example.com/roles" => ["support"]}
      assert {:ok, ["support"]} = Claims.get(claims, "https://example.com/roles")
    end

    test "prefers the longest existing key, then continues below it" do
      claims = %{"a.b" => %{"c" => 1}, "a" => %{"b" => %{"c" => 2}}}
      assert {:ok, 1} = Claims.get(claims, "a.b.c")
    end

    test "falls back to a shorter prefix when the longer one dead-ends" do
      claims = %{"a.b" => %{"x" => 1}, "a" => %{"b" => %{"c" => 2}}}
      assert {:ok, 2} = Claims.get(claims, "a.b.c")
    end

    test "is :error for a missing claim or a path through a non-map" do
      assert :error = Claims.get(%{}, "sub")
      assert :error = Claims.get(%{"o11y" => "flat"}, "o11y.role")
      assert :error = Claims.get(%{"o11y" => %{}}, "o11y.role")
    end
  end

  describe "strings/1" do
    test "accepts a string or a list of strings" do
      assert {:ok, ["a"]} = Claims.strings("a")
      assert {:ok, ["a", "b"]} = Claims.strings(["a", "b"])
      assert {:ok, []} = Claims.strings([])
    end

    test "refuses anything else" do
      assert :error = Claims.strings(["a", 1])
      assert :error = Claims.strings(%{"a" => 1})
      assert :error = Claims.strings(nil)
    end
  end

  describe "scalars/1" do
    test "wraps a single scalar and accepts a list of scalars" do
      assert {:ok, [42]} = Claims.scalars(42)
      assert {:ok, ["p1"]} = Claims.scalars("p1")
      assert {:ok, ["p1", 2, true]} = Claims.scalars(["p1", 2, true])
    end

    test "refuses nested values and nil" do
      assert :error = Claims.scalars([["nested"]])
      assert :error = Claims.scalars(%{"a" => 1})
      assert :error = Claims.scalars(nil)
      assert :error = Claims.scalars([1.5])
    end
  end
end
