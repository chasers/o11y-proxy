defmodule O11yProxy.Auth.OIDCTest do
  use ExUnit.Case, async: false

  alias O11yProxy.Auth.OIDC, as: Authenticator
  alias O11yProxy.Auth.SPIFFE
  alias O11yProxy.{Caller, Policy}
  alias O11yProxy.Policy.Constraint
  alias O11yProxy.Test.OIDC

  @policies %{
    "support" => %Policy{
      name: "support",
      sources: ["metrics"],
      constraints: [
        %Constraint{
          field: "labels.project",
          require: true,
          allowed: [],
          allowed_claim: "o11y.projects"
        }
      ]
    },
    "sre" => %Policy{name: "sre", sources: :all, raw: :allow},
    "readonly" => %Policy{name: "readonly", sources: ["metrics"]},
    "111122223333/sre" => %Policy{name: "111122223333/sre", sources: ["metrics"]}
  }

  setup_all do
    %{key: OIDC.key("k1")}
  end

  setup %{key: key} = context do
    OIDC.start_keys(OIDC.start_issuer([key]))
    oidc = OIDC.config(Map.get(context, :oidc, %{}))
    Application.put_env(:o11y_proxy, :oidc, oidc)
    Application.put_env(:o11y_proxy, :policies, @policies)

    on_exit(fn ->
      Application.delete_env(:o11y_proxy, :oidc)
      Application.delete_env(:o11y_proxy, :policies)
    end)

    :ok
  end

  defp authenticate(key, claims, header \\ %{}) do
    Authenticator.authenticate([{"authorization", "Bearer " <> OIDC.token(key, claims, header)}])
  end

  test "maps a valid token to a caller with its role's policy, bound to its claims", %{key: key} do
    claims =
      OIDC.claims(%{"sub" => "alice", "o11y" => %{"role" => "support", "projects" => ["p1"]}})

    assert {:ok, %Caller{id: "alice", policy: policy, claims: ^claims}} =
             authenticate(key, claims)

    assert policy.name == "support"
    assert [%Constraint{allowed: ["p1"]}] = policy.constraints
  end

  test "accepts the role claim as a list with exactly one configured role", %{key: key} do
    claims = OIDC.claims(%{"o11y" => %{"role" => ["employee", "sre"]}})
    assert {:ok, %Caller{policy: %Policy{name: "sre"}}} = authenticate(key, claims)
  end

  test "refuses a token holding two roles that both have policies", %{key: key} do
    claims = OIDC.claims(%{"o11y" => %{"role" => ["sre", "support"]}})
    assert {:error, {:forbidden, message}} = authenticate(key, claims)
    assert message =~ "more than one role"
  end

  test "refuses a token whose roles match no policy", %{key: key} do
    claims = OIDC.claims(%{"o11y" => %{"role" => "intern"}})
    assert {:error, {:forbidden, message}} = authenticate(key, claims)
    assert message =~ "intern"
  end

  @tag oidc: %{default_policy: "readonly"}
  test "falls back to default_policy when no role matches", %{key: key} do
    assert {:ok, %Caller{policy: %Policy{name: "readonly"}}} = authenticate(key, OIDC.claims())
  end

  @tag oidc: %{identity_claim: "email"}
  test "takes the caller's id from the configured identity claim", %{key: key} do
    claims = OIDC.claims(%{"email" => "a@example.com", "o11y" => %{"role" => "sre"}})
    assert {:ok, %Caller{id: "a@example.com"}} = authenticate(key, claims)

    assert {:error, {:unauthorized, message}} =
             authenticate(key, OIDC.claims(%{"o11y" => %{"role" => "sre"}}))

    assert message =~ "email"
  end

  test "refuses a malformed role claim", %{key: key} do
    claims = OIDC.claims(%{"o11y" => %{"role" => %{"nested" => true}}})
    assert {:error, {:forbidden, _}} = authenticate(key, claims)
  end

  test "is unauthorized for a token from an unknown key" do
    claims = OIDC.claims(%{"o11y" => %{"role" => "sre"}})
    assert {:error, {:unauthorized, message}} = authenticate(OIDC.key("k9"), claims)
    assert message =~ "not signed by a key this issuer publishes"
  end

  test "is unauthorized for an expired token", %{key: key} do
    claims =
      OIDC.claims(%{"exp" => System.system_time(:second) - 10, "o11y" => %{"role" => "sre"}})

    assert {:error, {:unauthorized, "token has expired"}} = authenticate(key, claims)
  end

  test "is unauthorized with no bearer token at all" do
    assert {:error, {:unauthorized, _}} = Authenticator.authenticate([])
  end

  describe "with spiffe: deriving roles from a SPIFFE ID" do
    @trust_domain "mint.example.com"
    @aws_path {["/aws/{account}/*/role/{role}"], ["{account}/{role}", "{role}"]}
    @spiffe_oidc %{role_claim: "sub", spiffe: {@trust_domain, [@aws_path]}}

    setup context do
      case Map.get(context, :oidc) do
        %{spiffe: {domain, paths}} = overrides ->
          {:ok, spiffe} = SPIFFE.compile(domain, paths)
          Application.put_env(:o11y_proxy, :oidc, OIDC.config(%{overrides | spiffe: spiffe}))

        _ ->
          :ok
      end

      :ok
    end

    defp sub(account, role),
      do: "spiffe://#{@trust_domain}/aws/#{account}/ap-southeast-1/role/#{role}"

    @tag oidc: @spiffe_oidc
    test "an account-pinned policy wins over the role's policy for that account", %{key: key} do
      id = sub("111122223333", "sre")

      assert {:ok, %Caller{id: ^id, policy: %Policy{name: "111122223333/sre"}}} =
               authenticate(key, OIDC.claims(%{"sub" => id}))
    end

    @tag oidc: @spiffe_oidc
    test "a role-only policy matches the role in every other account", %{key: key} do
      assert {:ok, %Caller{policy: %Policy{name: "sre"}}} =
               authenticate(key, OIDC.claims(%{"sub" => sub("444455556666", "sre")}))

      assert {:ok, %Caller{policy: %Policy{name: "support"}}} =
               authenticate(key, OIDC.claims(%{"sub" => sub("444455556666", "support")}))
    end

    @tag oidc: @spiffe_oidc
    test "an unmatched role is refused with the roles it gave, account included", %{key: key} do
      assert {:error, {:forbidden, message}} =
               authenticate(key, OIDC.claims(%{"sub" => sub("444455556666", "intern")}))

      assert message =~ "444455556666/intern, intern"
    end

    @tag oidc: @spiffe_oidc
    test "an ID that matches no pattern, or is not SPIFFE at all, yields no role",
         %{key: key} do
      assert {:error, {:forbidden, message}} =
               authenticate(key, OIDC.claims(%{"sub" => "spiffe://#{@trust_domain}/k8s/sa/sre"}))

      assert message =~ "matches no configured path pattern"

      assert {:error, {:forbidden, message}} =
               authenticate(key, OIDC.claims(%{"sub" => "spiffe://other.example.com/x"}))

      assert message =~ "trust domain other.example.com"

      assert {:error, {:forbidden, message}} = authenticate(key, OIDC.claims(%{"sub" => "sre"}))
      assert message =~ "not a valid SPIFFE ID"
    end

    @tag oidc: Map.put(@spiffe_oidc, :default_policy, "readonly")
    test "falls back to default_policy when the ID yields no matching role", %{key: key} do
      assert {:ok, %Caller{policy: %Policy{name: "readonly"}}} =
               authenticate(key, OIDC.claims(%{"sub" => sub("444455556666", "intern")}))

      assert {:ok, %Caller{policy: %Policy{name: "readonly"}}} =
               authenticate(key, OIDC.claims(%{"sub" => "not-spiffe"}))
    end

    # The ID sits in its own claim here, since a non-string sub is already refused by the
    # identity check before a policy is chosen.
    @tag oidc: Map.merge(@spiffe_oidc, %{role_claim: "workload", default_policy: "readonly"})
    test "refuses a role claim that is not a string, even with a default", %{key: key} do
      for value <- [[sub("111122223333", "sre")], %{"id" => "x"}, 42] do
        assert {:error, {:forbidden, message}} =
                 authenticate(key, OIDC.claims(%{"workload" => value}))

        assert message =~ "must be a string holding a SPIFFE ID"
      end
    end

    @tag oidc: %{
           @spiffe_oidc
           | spiffe: {@trust_domain, [{["/aws/111122223333/*/role/{role}"], ["{role}"]}]}
         }
    test "a pattern pinning the account ignores every other account", %{key: key} do
      assert {:ok, %Caller{policy: %Policy{name: "sre"}}} =
               authenticate(key, OIDC.claims(%{"sub" => sub("111122223333", "sre")}))

      assert {:error, {:forbidden, _}} =
               authenticate(key, OIDC.claims(%{"sub" => sub("444455556666", "sre")}))
    end

    test "refuses rather than crashes when spiffe has no role_claim to read" do
      {:ok, spiffe} = SPIFFE.compile(@trust_domain, [@aws_path])
      config = %{spiffe: spiffe}

      assert {:error, {:forbidden, message}} =
               Authenticator.select_policy(%{"sub" => sub("1", "sre")}, config, @policies)

      assert message =~ "without a role_claim"
    end
  end
end
