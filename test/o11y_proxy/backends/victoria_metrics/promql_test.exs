defmodule O11yProxy.Backends.VictoriaMetrics.PromQLTest do
  use ExUnit.Case, async: true

  alias O11yProxy.Backends.VictoriaMetrics.PromQL
  alias O11yProxy.Query.Filter

  describe "build_selector/1" do
    test "a name-only filter compiles to a bare metric name" do
      assert {:ok, "http_requests_total"} =
               PromQL.build_selector([
                 %Filter{field: "name", op: :eq, value: "http_requests_total"}
               ])
    end

    test "name plus label matchers" do
      assert {:ok, selector} =
               PromQL.build_selector([
                 %Filter{field: "name", op: :eq, value: "http_requests_total"},
                 %Filter{field: "labels.service", op: :eq, value: "checkout-api"}
               ])

      assert selector == ~s(http_requests_total{service="checkout-api"})
    end

    test "in on a label becomes an anchored alternation of literal values" do
      assert {:ok, ~s(up{project=~"p1|p2"})} =
               PromQL.build_selector([
                 %Filter{field: "name", op: :eq, value: "up"},
                 %Filter{field: "labels.project", op: :in, value: ["p1", "p2"]}
               ])
    end

    test "in quotes regex metacharacters, so a value only ever matches itself" do
      assert {:ok, selector} =
               PromQL.build_selector([
                 %Filter{field: "name", op: :eq, value: "up"},
                 %Filter{field: "labels.project", op: :in, value: ["a.b", "c|d", "e f", 42]}
               ])

      assert selector == ~S(up{project=~"a\\.b|c\\|d|e f|42"})
    end

    test "in escapes quotes so a value cannot close the matcher" do
      assert {:ok, selector} =
               PromQL.build_selector([
                 %Filter{field: "name", op: :eq, value: "up"},
                 %Filter{field: "labels.project", op: :in, value: [~s[x"} or vector(1) #]]}
               ])

      assert selector == ~S[up{project=~"x\"\\} or vector\\(1\\) #"}]
    end

    test "in needs a non-empty list" do
      for value <- [[], "p1"] do
        assert {:error, {:invalid_query, _}} =
                 PromQL.build_selector([
                   %Filter{field: "name", op: :eq, value: "up"},
                   %Filter{field: "labels.project", op: :in, value: value}
                 ])
      end
    end

    test "a bare label-only selector (no name) is valid MetricsQL" do
      assert {:ok, ~s({service="checkout-api"})} =
               PromQL.build_selector([
                 %Filter{field: "labels.service", op: :eq, value: "checkout-api"}
               ])
    end

    test "neq and regex matchers" do
      assert {:ok, sel} =
               PromQL.build_selector([
                 %Filter{field: "name", op: :eq, value: "up"},
                 %Filter{field: "labels.env", op: :neq, value: "dev"},
                 %Filter{field: "labels.service", op: :regex, value: "checkout.*"}
               ])

      assert sel == ~s(up{env!="dev",service=~"checkout.*"})
    end

    test "rejects neither a name nor a label matcher" do
      assert {:error, {:invalid_query, _}} = PromQL.build_selector([])
    end

    test "rejects more than one name filter" do
      assert {:error, {:invalid_query, _}} =
               PromQL.build_selector([
                 %Filter{field: "name", op: :eq, value: "a"},
                 %Filter{field: "name", op: :eq, value: "b"}
               ])
    end

    test "rejects a non-eq operator on name" do
      assert {:error, {:unsupported_operator, :contains}} =
               PromQL.build_selector([%Filter{field: "name", op: :contains, value: "http"}])
    end

    test "rejects an unsupported operator on a label matcher" do
      assert {:error, {:unsupported_operator, :gte}} =
               PromQL.build_selector([
                 %Filter{field: "name", op: :eq, value: "up"},
                 %Filter{field: "labels.duration", op: :gte, value: "5"}
               ])
    end

    test "rejects a field that isn't name or labels.*" do
      assert {:error, {:unknown_field, "body"}} =
               PromQL.build_selector([
                 %Filter{field: "name", op: :eq, value: "up"},
                 %Filter{field: "body", op: :eq, value: "x"}
               ])
    end

    test "escapes a double quote and backslash in a label value, never breaking out of the string" do
      # literal value: foo"; bar\baz  (one double quote, one backslash)
      hostile_value = "foo\"; bar\\baz"

      assert {:ok, sel} =
               PromQL.build_selector([
                 %Filter{field: "name", op: :eq, value: "up"},
                 %Filter{field: "labels.service", op: :eq, value: hostile_value}
               ])

      # escaped: the quote becomes \", the backslash becomes \\, in that order
      assert sel == "up{service=\"foo\\\"; bar\\\\baz\"}"
    end

    test "injection corpus: hostile label values stay inside the quotes" do
      hostile = [
        "'; DROP TABLE users; --",
        ~s("service"="evil"),
        "${jndi:ldap://evil/a}",
        String.duplicate("a", 10_000)
      ]

      for value <- hostile do
        assert {:ok, sel} =
                 PromQL.build_selector([
                   %Filter{field: "name", op: :eq, value: "up"},
                   %Filter{field: "labels.service", op: :eq, value: value}
                 ])

        # exactly one label matcher was produced — a hostile value cannot forge a second
        assert Enum.count_until(String.split(sel, "\","), 3) <= 2
        assert String.starts_with?(sel, ~s(up{service="))
      end
    end
  end

  describe "step_seconds/3" do
    test "targets roughly the given number of points" do
      assert PromQL.step_seconds(~U[2026-09-05 19:00:00Z], ~U[2026-09-05 20:00:00Z], 50) == 72
    end

    test "never returns less than one second" do
      assert PromQL.step_seconds(~U[2026-09-05 19:00:00Z], ~U[2026-09-05 19:00:00Z], 50) == 1
    end
  end
end
