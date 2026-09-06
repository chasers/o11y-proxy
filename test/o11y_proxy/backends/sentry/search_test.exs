defmodule O11yProxy.Backends.Sentry.SearchTest do
  use ExUnit.Case, async: true

  alias O11yProxy.Backends.Sentry.Search
  alias O11yProxy.Query.Filter

  describe "build_query/1 — one clause per field" do
    test "empty filter list compiles to an empty string" do
      assert {:ok, ""} = Search.build_query([])
    end

    test "severity eq maps onto level:, through the canonical->Sentry vocabulary" do
      assert {:ok, ~s(level:"error")} =
               Search.build_query([%Filter{field: "severity", op: :eq, value: "error"}])

      assert {:ok, ~s(level:"warning")} =
               Search.build_query([%Filter{field: "severity", op: :eq, value: "warn"}])
    end

    test "an unrecognized severity value passes through unchanged, still quoted" do
      assert {:ok, ~s(level:"sample")} =
               Search.build_query([%Filter{field: "severity", op: :eq, value: "sample"}])
    end

    test "severity rejects any operator other than eq" do
      assert {:error, {:unsupported_operator, :gte}} =
               Search.build_query([%Filter{field: "severity", op: :gte, value: "error"}])
    end

    test "trace_id eq maps onto trace:" do
      assert {:ok, ~s(trace:"abc123")} =
               Search.build_query([%Filter{field: "trace_id", op: :eq, value: "abc123"}])
    end

    test "trace_id rejects any operator other than eq" do
      assert {:error, {:unsupported_operator, :contains}} =
               Search.build_query([%Filter{field: "trace_id", op: :contains, value: "abc"}])
    end

    test "body contains compiles to a bare quoted term" do
      assert {:ok, ~s("timeout")} =
               Search.build_query([%Filter{field: "body", op: :contains, value: "timeout"}])
    end

    test "body rejects any operator other than contains" do
      assert {:error, {:unsupported_operator, :eq}} =
               Search.build_query([%Filter{field: "body", op: :eq, value: "timeout"}])
    end

    test "an unmapped field fails the whole compile, not silently dropped" do
      assert {:error, {:unknown_field, "service"}} =
               Search.build_query([%Filter{field: "service", op: :eq, value: "checkout-api"}])
    end

    test "multiple filters space-join in order" do
      assert {:ok, query} =
               Search.build_query([
                 %Filter{field: "severity", op: :eq, value: "error"},
                 %Filter{field: "body", op: :contains, value: "timeout"}
               ])

      assert query == ~s(level:"error" "timeout")
    end
  end

  describe "build_query/1 — escaping and injection safety" do
    test "escapes a double quote and backslash in a value, never breaking out of the string" do
      # literal value: foo"; bar\baz  (one double quote, one backslash)
      hostile_value = "foo\"; bar\\baz"

      assert {:ok, query} =
               Search.build_query([%Filter{field: "body", op: :contains, value: hostile_value}])

      assert query == "\"foo\\\"; bar\\\\baz\""
    end

    @hostile [
      "'; DROP TABLE users; --",
      ~s("' OR "1"="1),
      "${jndi:ldap://evil/a}",
      "<script>alert(1)</script>",
      String.duplicate("a", 10_000),
      "{evil:String}",
      "*/ UNION SELECT * FROM secrets--",
      ".*",
      # Sentry-specific: an unescaped colon could otherwise open a forged field:value
      # token, and an unescaped quote could otherwise close the wrapping string early.
      "level:fatal",
      ~s(fake" level:"fatal)
    ]

    test "injection corpus: a hostile value can only ever land inside the wrapping quotes" do
      for value <- @hostile do
        assert {:ok, query} =
                 Search.build_query([%Filter{field: "body", op: :contains, value: value}])

        stripped =
          query
          |> String.replace("\\\\", "")
          |> String.replace("\\\"", "")

        assert stripped |> String.replace(~r/[^"]/, "") |> String.length() == 2,
               "hostile value #{inspect(value)} forged an extra quote in: #{inspect(query)}"
      end
    end
  end

  describe "map_level/1" do
    test "maps every canonical severity onto Sentry's level vocabulary" do
      assert Search.map_level("trace") == "debug"
      assert Search.map_level("debug") == "debug"
      assert Search.map_level("info") == "info"
      assert Search.map_level("warn") == "warning"
      assert Search.map_level("error") == "error"
      assert Search.map_level("fatal") == "fatal"
    end

    test "is case-insensitive" do
      assert Search.map_level("ERROR") == "error"
    end
  end
end
