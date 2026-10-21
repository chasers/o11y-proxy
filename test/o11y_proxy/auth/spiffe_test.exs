defmodule O11yProxy.Auth.SPIFFETest do
  use ExUnit.Case, async: true

  alias O11yProxy.Auth.SPIFFE

  @domain "mint.example.com"
  @prefix "spiffe://mint.example.com"
  @aws ["/aws/{account}/*/role/{role}"]
  @account_then_role ["{account}/{role}", "{role}"]

  defp spiffe!(paths, policy_names) do
    {:ok, spiffe} = SPIFFE.compile(@domain, paths, policy_names)
    spiffe
  end

  defp compile_error(paths, policy_names) do
    assert {:error, message} = SPIFFE.compile(@domain, paths, policy_names)
    message
  end

  describe "parse/1" do
    test "splits a valid ID into its trust domain and path segments" do
      assert {:ok, @domain, ["aws", "111122223333", "ap-southeast-1", "role", "sre"]} =
               SPIFFE.parse(@prefix <> "/aws/111122223333/ap-southeast-1/role/sre")
    end

    test "accepts an ID with no path, and the full segment alphabet" do
      assert {:ok, @domain, []} = SPIFFE.parse(@prefix)
      assert {:ok, "a_b-1.c", ["Az09._-"]} = SPIFFE.parse("spiffe://a_b-1.c/Az09._-")
    end

    test "refuses anything the spec rules out" do
      for id <- [
            "https://mint.example.com/role/sre",
            "SPIFFE://mint.example.com/role/sre",
            "spiffe://Mint.example.com/role/sre",
            "spiffe:///role/sre",
            "spiffe://mint.example.com:443/role/sre",
            "spiffe://user@mint.example.com/role/sre",
            "spiffe://mint.example.com/",
            "spiffe://mint.example.com/role/sre/",
            "spiffe://mint.example.com/role//sre",
            "spiffe://mint.example.com/role/./sre",
            "spiffe://mint.example.com/role/../sre",
            "spiffe://mint.example.com/role/sre?x=1",
            "spiffe://mint.example.com/role/sre#frag",
            "spiffe://mint.example.com/role/s%72e",
            "spiffe://mint.example.com/role/s re",
            "spiffe://mint.example.com/role/sré"
          ] do
        assert SPIFFE.parse(id) == :error, "expected #{inspect(id)} to be refused"
      end
    end

    test "refuses an ID over 2048 bytes and a trust domain over 255" do
      assert :error = SPIFFE.parse(@prefix <> "/" <> String.duplicate("a", 2048))
      assert :error = SPIFFE.parse("spiffe://" <> String.duplicate("a", 256) <> "/x")
    end

    test "refuses a value that is not a string" do
      assert :error = SPIFFE.parse(nil)
      assert :error = SPIFFE.parse(["spiffe://mint.example.com/x"])
    end
  end

  describe "compile/3" do
    test "compiles literals, wildcards, captures and templates" do
      assert {:ok, %SPIFFE{trust_domain: @domain, patterns: [pattern], policy_names: names}} =
               SPIFFE.compile(@domain, @aws, ["{account}/{role}", "role-{role}"])

      assert pattern == [
               {:literal, "aws"},
               {:capture, "account"},
               :any,
               {:literal, "role"},
               {:capture, "role"}
             ]

      assert names == [
               [{:capture, "account"}, "/", {:capture, "role"}],
               ["role-", {:capture, "role"}]
             ]
    end

    test "takes any lowercase capture name, and keeps it a string" do
      assert {:ok, %SPIFFE{patterns: [[_, {:capture, "service_account2"}]]}} =
               SPIFFE.compile(@domain, ["/ns/{service_account2}"], ["{service_account2}"])
    end

    test "refuses a trust domain that no valid ID could carry" do
      for domain <- ["", "Mint.example.com", "spiffe://mint.example.com", "mint.example.com/x"] do
        assert {:error, message} = SPIFFE.compile(domain, ["/{role}"], ["{role}"])
        assert message =~ "trust_domain"
      end
    end

    test "needs at least one path and one policy name" do
      assert compile_error([], ["{role}"]) =~ "paths needs at least one entry"
      assert compile_error(["/{role}"], []) =~ "policy_names needs at least one entry"
    end

    test "refuses path patterns no ID could match" do
      for path <- [
            "role/{role}",
            "/ro*le/{role}",
            "/role//{role}",
            "/role/{role}/",
            "/../{role}",
            "/{Role}",
            "/{9lives}",
            "/{}",
            "/{role",
            "/x{role}"
          ] do
        assert compile_error([path], ["{role}"]) =~ inspect(path),
               "expected #{inspect(path)} to be refused"
      end
    end

    test "refuses a pattern capturing one name twice" do
      assert compile_error(["/{role}/{role}"], ["{role}"]) =~ "captures {role} more than once"
    end

    test "refuses malformed templates" do
      for {template, complaint} <- [
            {"", "is empty"},
            {"{role", "no closing }"},
            {"role}", "no opening {"},
            {"{Role}", "not a valid {name}"},
            {"{}", "not a valid {name}"}
          ] do
        assert compile_error(["/{role}"], [template]) =~ complaint
      end
    end

    test "refuses a template that no pattern can fill" do
      message = compile_error(@aws, ["{account}/{region}/{role}", "{role}"])
      assert message =~ ~s("{account}/{region}/{role}")
      assert message =~ "no path captures"
    end

    test "refuses a pattern that fills no template" do
      message = compile_error(["/aws/{account}/*/role/{role}", "/k8s/{sa}"], ["{role}"])
      assert message =~ ~s("/k8s/{sa}")
      assert message =~ "fills no policy_names entry"
    end

    test "accepts a template that only some patterns fill" do
      assert {:ok, _} =
               SPIFFE.compile(
                 @domain,
                 ["/aws/{account}/{region}/role/{role}", "/aws/{account}/role/{role}"],
                 ["{account}/{region}/{role}", "{account}/{role}"]
               )
    end
  end

  describe "roles/2" do
    test "fills the templates in order from the captures" do
      spiffe = spiffe!(@aws, @account_then_role)
      id = @prefix <> "/aws/111122223333/ap-southeast-1/role/metrics-writer"

      assert {:ok, ["111122223333/metrics-writer", "metrics-writer"]} = SPIFFE.roles(spiffe, id)
    end

    test "follows the configured order, not specificity" do
      spiffe = spiffe!(@aws, ["{role}", "{account}/{role}"])

      assert {:ok, ["sre", "111122223333/sre"]} =
               SPIFFE.roles(spiffe, @prefix <> "/aws/111122223333/eu-west-1/role/sre")
    end

    test "skips a template whose capture the matched pattern did not make" do
      spiffe =
        spiffe!(
          ["/aws/{account}/{region}/role/{role}", "/aws/{account}/role/{role}"],
          ["{account}/{region}/{role}", "{account}/{role}", "{role}"]
        )

      assert {:ok, ["1111/eu-west-1/sre", "1111/sre", "sre"]} =
               SPIFFE.roles(spiffe, @prefix <> "/aws/1111/eu-west-1/role/sre")

      assert {:ok, ["1111/sre", "sre"]} = SPIFFE.roles(spiffe, @prefix <> "/aws/1111/role/sre")
    end

    test "drops duplicate names, keeping the first position" do
      spiffe = spiffe!(["/{a}/{b}"], ["{a}", "{b}"])
      assert {:ok, ["same"]} = SPIFFE.roles(spiffe, @prefix <> "/same/same")
    end

    test "works for layouts with no account at all" do
      spiffe = spiffe!(["/ns/{namespace}/sa/{sa}"], ["{namespace}/{sa}", "{sa}"])

      assert {:ok, ["payments/ingest", "ingest"]} =
               SPIFFE.roles(spiffe, @prefix <> "/ns/payments/sa/ingest")
    end

    test "matches literals exactly, case included, and segment counts exactly" do
      spiffe = spiffe!(["/aws/111122223333/*/role/{role}"], ["{role}"])

      for path <- [
            "/aws/444455556666/eu-west-1/role/sre",
            "/AWS/111122223333/eu-west-1/role/sre",
            "/aws/111122223333/eu-west-1/role",
            "/aws/111122223333/eu-west-1/role/sre/extra",
            "/aws/111122223333/role/sre"
          ] do
        assert {:none, "matches no configured path pattern"} =
                 SPIFFE.roles(spiffe, @prefix <> path)
      end
    end

    test "accepts two patterns that agree on the names, refuses two that do not" do
      agreeing = spiffe!(@aws ++ ["/aws/{account}/eu-west-1/role/{role}"], @account_then_role)

      assert {:ok, ["111122223333/sre", "sre"]} =
               SPIFFE.roles(agreeing, @prefix <> "/aws/111122223333/eu-west-1/role/sre")

      disagreeing = spiffe!(@aws ++ ["/aws/{account}/{role}/role/*"], @account_then_role)

      assert {:error, message} =
               SPIFFE.roles(disagreeing, @prefix <> "/aws/111122223333/eu-west-1/role/sre")

      assert message =~ "more than one path pattern"
    end

    test "yields no role for another trust domain or an invalid ID" do
      spiffe = spiffe!(["/role/{role}"], ["{role}"])

      assert {:none, message} = SPIFFE.roles(spiffe, "spiffe://other.example.com/role/sre")
      assert message =~ "other.example.com"
      assert {:none, "is not a valid SPIFFE ID"} = SPIFFE.roles(spiffe, @prefix <> "/role/../sre")
      assert {:none, "is not a valid SPIFFE ID"} = SPIFFE.roles(spiffe, "sre")
    end
  end
end
