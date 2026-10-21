defmodule O11yProxy.Auth.SPIFFETest do
  use ExUnit.Case, async: true

  alias O11yProxy.Auth.SPIFFE

  @domain "mint.example.com"
  @prefix "spiffe://mint.example.com"
  @aws {"/aws/{account}/*/role/{role}", ["{account}/{role}", "{role}"]}

  defp spiffe!(paths) do
    {:ok, spiffe} = SPIFFE.compile(@domain, paths)
    spiffe
  end

  defp compile_error(paths) do
    assert {:error, message} = SPIFFE.compile(@domain, paths)
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

  describe "compile/2" do
    test "compiles literals, wildcards and captures, and tokenizes templates" do
      assert {:ok, %SPIFFE{trust_domain: @domain, paths: [{pattern, templates}]}} =
               SPIFFE.compile(@domain, [
                 {"/aws/{account}/*/role/{role}", ["{account}/{role}", "role:{role}"]}
               ])

      assert pattern == [
               {:literal, "aws"},
               {:capture, "account"},
               :any,
               {:literal, "role"},
               {:capture, "role"}
             ]

      assert templates == [
               [{:capture, "account"}, {:other, "/"}, {:capture, "role"}],
               [{:segment, "role"}, {:other, ":"}, {:capture, "role"}]
             ]
    end

    test "takes any lowercase capture name, and keeps it a string" do
      assert {:ok, %SPIFFE{paths: [{[_, {:capture, "service_account2"}], _}]}} =
               SPIFFE.compile(@domain, [{"/ns/{service_account2}", ["{service_account2}"]}])

      assert {:ok, _} = SPIFFE.compile(@domain, [{"/{_x}", ["{_x}"]}])
    end

    test "refuses a trust domain that no valid ID could carry" do
      for domain <- ["", "Mint.example.com", "spiffe://mint.example.com", "mint.example.com/x"] do
        assert {:error, message} = SPIFFE.compile(domain, [{"/{role}", ["{role}"]}])
        assert message =~ "trust_domain"
      end
    end

    test "needs at least one path, and at least one policy name per path" do
      assert compile_error([]) =~ "paths needs at least one entry"
      assert compile_error([{"/{role}", []}]) =~ "needs at least one policy_names entry"
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
        assert compile_error([{path, ["{role}"]}]) =~ inspect(path),
               "expected #{inspect(path)} to be refused"
      end
    end

    test "refuses a pattern capturing one name twice" do
      assert compile_error([{"/{role}/{role}", ["{role}"]}]) =~ "captures {role} more than once"
    end

    test "refuses malformed templates" do
      for {template, complaint} <- [
            {"", "is empty"},
            {"{role", "no closing }"},
            {"role}", "no opening {"},
            {"{Role}", "not a valid {name}"},
            {"{}", "not a valid {name}"},
            {<<0xFF>>, "not valid UTF-8"}
          ] do
        assert compile_error([{"/{role}", [template]}]) =~ complaint
      end
    end

    test "refuses a template using a name its own pattern does not capture" do
      message = compile_error([{"/aws/{account}/*/role/{role}", ["{region}/{role}"]}])
      assert message =~ ~s("{region}/{role}")
      assert message =~ "does not capture"
    end

    test "refuses a {name} touching segment characters or another {name}" do
      # Each of these lets two different IDs fill the template to one name: a role named
      # "111122223333-admin" in any account fills {role} to the pinned name.
      for template <- [
            "{account}-{role}",
            "{account}.{role}",
            "{account}{role}",
            "x{role}",
            "{role}_x"
          ] do
        message = compile_error([{"/{account}/{role}", [template, "{role}"]}])
        assert message =~ "separate each {name}", "expected #{inspect(template)} to be refused"
      end
    end

    test "accepts separators no segment can hold" do
      for template <- [
            "{account}/{role}",
            "{account}:{role}",
            "aws:{role}",
            "{role}@prod",
            "{a} {b}"
          ] do
        assert {:ok, _} = SPIFFE.compile(@domain, [{"/{account}/{role}/{a}/{b}", [template]}]),
               "expected #{inspect(template)} to be accepted"
      end
    end

    test "refuses two templates that can produce the same name" do
      for {left, right} <- [
            # a role-only name colliding with a fixed one
            {{"/aws/{account}/*/role/{role}", ["{role}"]}, {"/ns/prod/sa/admin", ["admin"]}},
            # two layouts sharing a namespace under different names
            {@aws, {"/ns/{namespace}/sa/{sa}", ["{namespace}/{sa}"]}},
            {@aws, {"/ns/*/sa/{sa}", ["{sa}"]}},
            # within one path, two captures in the same position
            {{"/{a}/{b}", ["{a}"]}, {"/{a}/{b}/x", ["{b}"]}}
          ] do
        assert compile_error([left, right]) =~ "can produce the same policy name"
      end

      assert compile_error([{"/{a}/{b}", ["{a}", "{b}"]}]) =~ "can produce the same policy name"
    end

    test "accepts templates kept apart by fixed text" do
      assert {:ok, _} =
               SPIFFE.compile(@domain, [
                 @aws,
                 {"/ns/{namespace}/sa/{sa}", ["k8s:{namespace}/{sa}", "k8s:{sa}"]},
                 {"/ns/prod/sa/admin", ["pinned:admin"]}
               ])
    end

    test "accepts the same template text under several patterns" do
      assert {:ok, _} =
               SPIFFE.compile(@domain, [
                 {"/aws/{account}/{region}/role/{role}", ["{account}/{role}", "{role}"]},
                 {"/aws/{account}/role/{role}", ["{account}/{role}", "{role}"]}
               ])
    end
  end

  describe "produces?/2" do
    test "is true only for names some template can produce" do
      spiffe = spiffe!([@aws])

      assert SPIFFE.produces?(spiffe, "111122223333/sre")
      assert SPIFFE.produces?(spiffe, "sre")
      refute SPIFFE.produces?(spiffe, "111122223333/")
      refute SPIFFE.produces?(spiffe, "a/b/c")
      refute SPIFFE.produces?(spiffe, "role:sre")
      refute SPIFFE.produces?(spiffe, "")
    end

    test "matches fixed text exactly" do
      spiffe = spiffe!([{"/ns/*/sa/{sa}", ["k8s:{sa}"]}])

      assert SPIFFE.produces?(spiffe, "k8s:ingest")
      refute SPIFFE.produces?(spiffe, "ingest")
      refute SPIFFE.produces?(spiffe, "k8s:")
    end
  end

  describe "roles/2" do
    test "fills the path's templates in order from the captures" do
      spiffe = spiffe!([@aws])
      id = @prefix <> "/aws/111122223333/ap-southeast-1/role/metrics-writer"

      assert {:ok, ["111122223333/metrics-writer", "metrics-writer"]} = SPIFFE.roles(spiffe, id)
    end

    test "follows the configured order, not specificity" do
      spiffe = spiffe!([{"/aws/{account}/*/role/{role}", ["{role}", "{account}/{role}"]}])

      assert {:ok, ["sre", "111122223333/sre"]} =
               SPIFFE.roles(spiffe, @prefix <> "/aws/111122223333/eu-west-1/role/sre")
    end

    test "uses only the matched path's own templates" do
      spiffe = spiffe!([@aws, {"/ns/*/sa/{sa}", ["k8s:{sa}"]}])

      assert {:ok, ["k8s:sre"]} = SPIFFE.roles(spiffe, @prefix <> "/ns/default/sa/sre")
    end

    test "maps alternative layouts of one issuer to the same names" do
      spiffe =
        spiffe!([
          {"/aws/{account}/{region}/role/{role}", ["{account}/{role}", "{role}"]},
          {"/aws/{account}/role/{role}", ["{account}/{role}", "{role}"]}
        ])

      assert {:ok, ["1111/sre", "sre"]} =
               SPIFFE.roles(spiffe, @prefix <> "/aws/1111/eu-west-1/role/sre")

      assert {:ok, ["1111/sre", "sre"]} = SPIFFE.roles(spiffe, @prefix <> "/aws/1111/role/sre")
    end

    test "works for layouts with no account at all" do
      spiffe = spiffe!([{"/ns/{namespace}/sa/{sa}", ["{namespace}/{sa}", "{sa}"]}])

      assert {:ok, ["payments/ingest", "ingest"]} =
               SPIFFE.roles(spiffe, @prefix <> "/ns/payments/sa/ingest")
    end

    test "matches literals exactly, case included, and segment counts exactly" do
      spiffe = spiffe!([{"/aws/111122223333/*/role/{role}", ["{role}"]}])

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

    test "accepts two patterns giving the same names, refuses two that do not" do
      {_, names} = @aws
      agreeing = spiffe!([@aws, {"/aws/{account}/eu-west-1/role/{role}", names}])

      assert {:ok, ["111122223333/sre", "sre"]} =
               SPIFFE.roles(agreeing, @prefix <> "/aws/111122223333/eu-west-1/role/sre")

      disagreeing = spiffe!([@aws, {"/aws/{account}/{role}/role/*", names}])

      assert {:error, message} =
               SPIFFE.roles(disagreeing, @prefix <> "/aws/111122223333/eu-west-1/role/sre")

      assert message =~ "more than one path pattern"
    end

    test "yields no names for another trust domain or an invalid ID" do
      spiffe = spiffe!([{"/role/{role}", ["{role}"]}])

      assert {:none, message} = SPIFFE.roles(spiffe, "spiffe://other.example.com/role/sre")
      assert message =~ "other.example.com"
      assert {:none, "is not a valid SPIFFE ID"} = SPIFFE.roles(spiffe, @prefix <> "/role/../sre")
      assert {:none, "is not a valid SPIFFE ID"} = SPIFFE.roles(spiffe, "sre")
    end
  end
end
