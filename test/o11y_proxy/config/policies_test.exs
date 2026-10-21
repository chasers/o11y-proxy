defmodule O11yProxy.Config.PoliciesTest do
  use ExUnit.Case, async: true

  alias O11yProxy.Config.Policies
  alias O11yProxy.Policy
  alias O11yProxy.Policy.Constraint

  @sources ["prod_metrics", "prod_logs"]

  defp build(raw), do: Policies.build(raw, @sources)

  defp error!(raw) do
    assert {:error, {:invalid_block, block, message}} = build(raw)
    {block, message}
  end

  test "builds a full policy" do
    raw = %{
      "support" => %{
        "sources" => ["prod_metrics", "prod_logs"],
        "raw" => "deny",
        "modes" => ["summary", "sample"],
        "max_limit" => 500,
        "max_lookback" => "7d",
        "constraints" => [
          %{
            "sources" => ["prod_metrics"],
            "field" => "labels.project",
            "require" => true,
            "allowed_claim" => "o11y.projects"
          },
          %{"field" => "env", "inject" => true, "allowed" => ["prod"]}
        ]
      }
    }

    assert {:ok, %{"support" => policy}} = build(raw)

    assert %Policy{
             name: "support",
             sources: ["prod_metrics", "prod_logs"],
             raw: :deny,
             modes: [:summary, :sample],
             max_limit: 500,
             max_lookback: "7d",
             max_lookback_seconds: 604_800,
             constraints: [
               %Constraint{
                 sources: ["prod_metrics"],
                 field: "labels.project",
                 require: true,
                 inject: false,
                 allowed: [],
                 allowed_claim: "o11y.projects"
               },
               %Constraint{sources: :all, field: "env", inject: true, allowed: ["prod"]}
             ]
           } = policy
  end

  test "applies defaults: raw deny, every mode, no caps, no constraints" do
    assert {:ok, %{"sre" => policy}} = build(%{"sre" => %{"sources" => "*"}})

    assert %Policy{sources: :all, raw: :deny, modes: :all, max_limit: nil} = policy
    assert policy.constraints == []
  end

  test "an empty block is no policies" do
    assert {:ok, %{}} = build(%{})
  end

  test "requires sources" do
    assert {"policies.sre", message} = error!(%{"sre" => %{}})
    assert message =~ "sources"
  end

  test "refuses unknown keys, the same way every other block does" do
    assert {"policies.sre", message} = error!(%{"sre" => %{"sources" => "*", "max_rows" => 1}})
    assert message =~ "unknown options"
  end

  test "refuses a source name that is not configured, listing the configured ones" do
    assert {"policies.sre", message} = error!(%{"sre" => %{"sources" => ["prod_metrcs"]}})
    assert message =~ ~s(unknown source "prod_metrcs")
    assert message =~ "prod_metrics, prod_logs"
  end

  test "refuses an unknown source inside a constraint" do
    raw = %{
      "s" => %{
        "sources" => "*",
        "constraints" => [%{"sources" => ["nope"], "field" => "f", "allowed" => "*"}]
      }
    }

    assert {"policies.s.constraints[0]", _} = error!(raw)
  end

  test "refuses an unparseable max_lookback" do
    assert {_, message} = error!(%{"s" => %{"sources" => "*", "max_lookback" => "a week"}})
    assert message =~ "not a duration"
  end

  test "a constraint needs exactly one of allowed and allowed_claim" do
    neither = %{
      "s" => %{"sources" => "*", "constraints" => [%{"field" => "f", "require" => true}]}
    }

    both = %{
      "s" => %{
        "sources" => "*",
        "constraints" => [%{"field" => "f", "allowed" => ["a"], "allowed_claim" => "c"}]
      }
    }

    assert {_, neither_message} = error!(neither)
    assert neither_message =~ "set allowed"
    assert {_, both_message} = error!(both)
    assert both_message =~ "not both"
  end

  test "inject needs a bounded set" do
    raw = %{
      "s" => %{
        "sources" => "*",
        "constraints" => [%{"field" => "f", "inject" => true, "allowed" => "*"}]
      }
    }

    assert {_, message} = error!(raw)
    assert message =~ "inject needs"
  end

  test "raw: allow is refused alongside any constraint, since raw bypasses them" do
    raw = %{
      "s" => %{
        "sources" => "*",
        "raw" => "allow",
        "constraints" => [%{"field" => "f", "require" => true, "allowed" => "*"}]
      }
    }

    assert {"policies.s", message} = error!(raw)
    assert message =~ "raw: allow would bypass"
  end

  test "refuses a policies block that is not a mapping" do
    assert {:error, {:invalid_block_shape, :policies, _}} = Policies.build(["x"], @sources)
  end
end
