defmodule O11yProxy.PolicyTest do
  @moduledoc """
  Exhaustive tests for the pure policy engine: the source allow-list, the query-level caps,
  and every combination of a constraint's `require`/`inject`/`allowed` against a query that
  omits the field, filters it with `eq`, with `in`, or with an operator that could escape
  an allow-list.
  """

  use ExUnit.Case, async: true

  alias O11yProxy.Policy
  alias O11yProxy.Policy.Constraint
  alias O11yProxy.Query
  alias O11yProxy.Query.Filter

  @now ~U[2026-10-20 12:00:00Z]

  defp query(overrides \\ []) do
    struct!(
      %Query{
        sources: ["metrics"],
        signal: :metrics,
        from: DateTime.add(@now, -3600, :second),
        to: @now,
        filters: [%Filter{field: "name", op: :eq, value: "up"}],
        mode: :summary,
        limit: 50
      },
      overrides
    )
  end

  defp policy(overrides \\ []), do: struct!(%Policy{name: "support"}, overrides)

  defp with_filter(filter),
    do: query(filters: [%Filter{field: "name", op: :eq, value: "up"}, filter])

  defp forbidden!(result) do
    assert {:error, {:forbidden, message}} = result
    message
  end

  describe "no policy" do
    test "permits everything and leaves the query untouched" do
      q = query(raw: "up", limit: 10_000)
      assert {:ok, ^q} = Policy.authorize(nil, "anything", q, @now)
      assert Policy.permits_source?(nil, "anything")
      assert :ok = Policy.authorize_source(nil, "anything")
      assert :ok = Policy.authorize_lookup(nil, "anything")
      assert Policy.limit_cap(nil) == nil
      assert Policy.lookback_cap(nil) == nil
    end
  end

  describe "sources" do
    test "\"*\" permits every source" do
      assert Policy.permits_source?(policy(sources: :all), "x")
    end

    test "a list permits only its members, and the refusal names the allowed ones" do
      p = policy(sources: ["metrics", "logs"])
      assert Policy.permits_source?(p, "metrics")
      refute Policy.permits_source?(p, "errors")

      message = forbidden!(Policy.authorize(p, "errors", query(), @now))
      assert message =~ ~s(does not permit source "errors")
      assert message =~ "metrics, logs"
    end
  end

  describe "query-level caps" do
    test "raw is refused under raw: deny and allowed under raw: allow" do
      assert forbidden!(Policy.authorize(policy(), "metrics", query(raw: "up"), @now)) =~
               "raw"

      assert {:ok, _} = Policy.authorize(policy(raw: :allow), "metrics", query(raw: "up"), @now)
    end

    test "modes outside the allowed list are refused" do
      p = policy(modes: [:summary, :sample])
      assert {:ok, _} = Policy.authorize(p, "metrics", query(mode: :sample), @now)
      message = forbidden!(Policy.authorize(p, "metrics", query(mode: :full), @now))
      assert message =~ "mode full"
      assert message =~ "summary, sample"
    end

    test "a limit over max_limit is refused, not clamped" do
      p = policy(max_limit: 100)
      assert {:ok, _} = Policy.authorize(p, "metrics", query(limit: 100), @now)

      assert forbidden!(Policy.authorize(p, "metrics", query(limit: 101), @now)) =~
               "max_limit of 100"

      assert Policy.limit_cap(p) == 100
    end

    test "a from further back than max_lookback is refused, with a minute of slack" do
      p = policy(max_lookback: "1d", max_lookback_seconds: 86_400)
      at_cap = query(from: DateTime.add(@now, -86_400, :second))
      in_slack = query(from: DateTime.add(@now, -86_430, :second))
      beyond = query(from: DateTime.add(@now, -90_000, :second))

      assert {:ok, _} = Policy.authorize(p, "metrics", at_cap, @now)
      assert {:ok, _} = Policy.authorize(p, "metrics", in_slack, @now)
      message = forbidden!(Policy.authorize(p, "metrics", beyond, @now))
      assert message =~ "max_lookback of 1d"
      assert message =~ "2026-10-19T12:00:00Z"
      assert Policy.lookback_cap(p) == 86_400
    end
  end

  describe "a require constraint" do
    setup do
      constraint = %Constraint{field: "labels.project", require: true, allowed: ["p1", "p2"]}
      %{p: policy(constraints: [constraint])}
    end

    test "refuses a query without the field, naming the field and the allowed values", %{p: p} do
      message = forbidden!(Policy.authorize(p, "metrics", query(), @now))
      assert message =~ "requires a filter on labels.project"
      assert message =~ ~s(allowed values: "p1", "p2")
    end

    test "accepts eq and in within the allowed values", %{p: p} do
      eq = with_filter(%Filter{field: "labels.project", op: :eq, value: "p1"})
      in_ = with_filter(%Filter{field: "labels.project", op: :in, value: ["p1", "p2"]})
      assert {:ok, ^eq} = Policy.authorize(p, "metrics", eq, @now)
      assert {:ok, ^in_} = Policy.authorize(p, "metrics", in_, @now)
    end

    test "refuses values outside the allowed set, naming the offending ones", %{p: p} do
      eq = with_filter(%Filter{field: "labels.project", op: :eq, value: "p3"})
      in_ = with_filter(%Filter{field: "labels.project", op: :in, value: ["p1", "p3", "p4"]})

      assert forbidden!(Policy.authorize(p, "metrics", eq, @now)) =~
               ~s(value "p3" is not permitted)

      assert forbidden!(Policy.authorize(p, "metrics", in_, @now)) =~
               ~s(values "p3", "p4" are not permitted)
    end

    test "refuses every operator that could escape the allow-list", %{p: p} do
      for op <- [:neq, :regex, :contains, :exists, :gte, :lte] do
        q = with_filter(%Filter{field: "labels.project", op: op, value: "p1"})

        assert forbidden!(Policy.authorize(p, "metrics", q, @now)) =~
                 "must use op eq or in, not #{op}"
      end
    end

    test "refuses in with a non-list value", %{p: p} do
      q = with_filter(%Filter{field: "labels.project", op: :in, value: "p1"})
      assert forbidden!(Policy.authorize(p, "metrics", q, @now)) =~ "needs a list"
    end

    test "checks every filter on the field, not only the first", %{p: p} do
      q =
        query(
          filters: [
            %Filter{field: "labels.project", op: :eq, value: "p1"},
            %Filter{field: "labels.project", op: :eq, value: "p9"}
          ]
        )

      assert forbidden!(Policy.authorize(p, "metrics", q, @now)) =~ "p9"
    end

    test "compares values as strings, so a numeric claim matches a JSON string filter" do
      p = policy(constraints: [%Constraint{field: "project", require: true, allowed: [42]}])
      q = with_filter(%Filter{field: "project", op: :eq, value: "42"})
      assert {:ok, _} = Policy.authorize(p, "metrics", q, @now)
    end
  end

  describe "require with allowed: :any" do
    test "demands the field but accepts any value" do
      p = policy(constraints: [%Constraint{field: "labels.project", require: true}])
      assert forbidden!(Policy.authorize(p, "metrics", query(), @now)) =~ "any value is allowed"

      q = with_filter(%Filter{field: "labels.project", op: :eq, value: "whatever"})
      assert {:ok, _} = Policy.authorize(p, "metrics", q, @now)
    end
  end

  describe "an inject constraint" do
    test "adds eq for a single allowed value" do
      p = policy(constraints: [%Constraint{field: "project", inject: true, allowed: ["p1"]}])
      assert {:ok, %Query{filters: filters}} = Policy.authorize(p, "metrics", query(), @now)
      assert List.last(filters) == %Filter{field: "project", op: :eq, value: "p1"}
    end

    test "adds in for several allowed values" do
      p =
        policy(constraints: [%Constraint{field: "project", inject: true, allowed: ["p1", "p2"]}])

      assert {:ok, %Query{filters: filters}} = Policy.authorize(p, "metrics", query(), @now)
      assert List.last(filters) == %Filter{field: "project", op: :in, value: ["p1", "p2"]}
    end

    test "leaves an in-bounds filter alone and still refuses an out-of-bounds one" do
      p =
        policy(constraints: [%Constraint{field: "project", inject: true, allowed: ["p1", "p2"]}])

      ok = with_filter(%Filter{field: "project", op: :eq, value: "p2"})
      bad = with_filter(%Filter{field: "project", op: :eq, value: "p3"})
      assert {:ok, ^ok} = Policy.authorize(p, "metrics", ok, @now)
      assert {:error, {:forbidden, _}} = Policy.authorize(p, "metrics", bad, @now)
    end

    test "refuses when the token grants no values, naming the claim" do
      p =
        policy(
          constraints: [
            %Constraint{
              field: "project",
              inject: true,
              allowed: [],
              allowed_claim: "o11y.projects"
            }
          ]
        )

      message = forbidden!(Policy.authorize(p, "metrics", query(), @now))
      assert message =~ "grants no project values (from claim o11y.projects)"
    end
  end

  describe "a constraint that neither requires nor injects" do
    test "only bounds values when the field is used" do
      p = policy(constraints: [%Constraint{field: "project", allowed: ["p1"]}])
      assert {:ok, _} = Policy.authorize(p, "metrics", query(), @now)

      bad = with_filter(%Filter{field: "project", op: :eq, value: "p2"})
      assert {:error, {:forbidden, _}} = Policy.authorize(p, "metrics", bad, @now)
    end
  end

  describe "constraint scoping by source" do
    test "applies only to the sources it names" do
      constraint = %Constraint{sources: ["metrics"], field: "labels.project", require: true}
      p = policy(constraints: [constraint])

      assert {:error, {:forbidden, _}} = Policy.authorize(p, "metrics", query(), @now)
      assert {:ok, _} = Policy.authorize(p, "logs", query(), @now)
    end

    test "constraints apply in order, so an injected filter satisfies a later require" do
      p =
        policy(
          constraints: [
            %Constraint{field: "project", inject: true, allowed: ["p1"]},
            %Constraint{field: "project", require: true, allowed: ["p1"]}
          ]
        )

      assert {:ok, _} = Policy.authorize(p, "metrics", query(), @now)
    end
  end

  describe "authorize_lookup/2" do
    test "allows a lookup on a permitted, unconstrained source" do
      assert :ok = Policy.authorize_lookup(policy(sources: ["errors"]), "errors")
    end

    test "refuses a lookup on a source outside the policy" do
      assert {:error, {:forbidden, _}} =
               Policy.authorize_lookup(policy(sources: ["logs"]), "errors")
    end

    test "refuses a lookup on a constrained source, since an ID cannot be scoped" do
      p = policy(constraints: [%Constraint{field: "project", inject: true, allowed: ["p1"]}])
      message = forbidden!(Policy.authorize_lookup(p, "errors"))
      assert message =~ "cannot be scoped by project"
    end
  end

  describe "bind/2" do
    defp claim_policy(path),
      do:
        policy(
          constraints: [
            %Constraint{field: "project", inject: true, allowed: [], allowed_claim: path}
          ]
        )

    test "resolves allowed values from the token's claim" do
      assert {:ok, %Policy{constraints: [c]}} =
               Policy.bind(claim_policy("o11y.projects"), %{
                 "o11y" => %{"projects" => ["p1", "p2"]}
               })

      assert c.allowed == ["p1", "p2"]
    end

    test "wraps a single scalar claim" do
      assert {:ok, %Policy{constraints: [c]}} =
               Policy.bind(claim_policy("project"), %{"project" => 7})

      assert c.allowed == [7]
    end

    test "binds a missing claim to no values" do
      assert {:ok, %Policy{constraints: [c]}} = Policy.bind(claim_policy("o11y.projects"), %{})
      assert c.allowed == []
    end

    test "refuses a malformed claim outright" do
      assert {:error, {:forbidden, message}} =
               Policy.bind(claim_policy("projects"), %{"projects" => %{"p1" => true}})

      assert message =~ "token claim projects must be"
    end

    test "leaves literal constraints untouched" do
      p = policy(constraints: [%Constraint{field: "project", allowed: ["p1"]}])
      assert {:ok, ^p} = Policy.bind(p, %{})
    end
  end
end
