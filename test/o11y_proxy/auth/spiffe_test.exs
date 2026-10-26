defmodule O11yProxy.Auth.SPIFFETest do
  use ExUnit.Case, async: true

  alias O11yProxy.Auth.SPIFFE

  @domain "mint.example.com"
  @prefix "spiffe://mint.example.com"
  @aws {["/aws/{account}/*/role/{role}"], ["{account}/{role}", "{role}"]}

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
      assert {:ok, %SPIFFE{trust_domain: @domain, entries: [{[pattern], templates}]}} =
               SPIFFE.compile(@domain, [
                 {["/aws/{account}/*/role/{role}"], ["{account}/{role}", "role:{role}"]}
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
      assert {:ok, %SPIFFE{entries: [{[[_, {:capture, "service_account2"}]], _}]}} =
               SPIFFE.compile(@domain, [{["/ns/{service_account2}"], ["{service_account2}"]}])

      assert {:ok, _} = SPIFFE.compile(@domain, [{["/{_x}"], ["{_x}"]}])
    end

    test "refuses a trust domain that no valid ID could carry" do
      for domain <- ["", "Mint.example.com", "spiffe://mint.example.com", "mint.example.com/x"] do
        assert {:error, message} = SPIFFE.compile(domain, [{["/{role}"], ["{role}"]}])
        assert message =~ "trust_domain"
      end
    end

    test "needs at least one entry, and a pattern and a policy name per entry" do
      assert compile_error([]) =~ "paths needs at least one entry"
      assert compile_error([{[], ["{role}"]}]) =~ "needs at least one pattern"
      assert compile_error([{["/{role}"], []}]) =~ "needs at least one policy_names entry"
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
        assert compile_error([{[path], ["{role}"]}]) =~ inspect(path),
               "expected #{inspect(path)} to be refused"
      end
    end

    test "refuses a pattern capturing one name twice" do
      assert compile_error([{["/{role}/{role}"], ["{role}"]}]) =~ "captures {role} more than once"
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
        assert compile_error([{["/{role}"], [template]}]) =~ complaint
      end
    end

    test "refuses a template using a name its own pattern does not capture" do
      message = compile_error([{["/aws/{account}/*/role/{role}"], ["{region}/{role}"]}])
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
        message = compile_error([{["/{account}/{role}"], [template, "{role}"]}])
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
        assert {:ok, _} = SPIFFE.compile(@domain, [{["/{account}/{role}/{a}/{b}"], [template]}]),
               "expected #{inspect(template)} to be accepted"
      end
    end

    test "refuses two templates that can produce the same name" do
      for {left, right} <- [
            # a role-only name colliding with a fixed one
            {{["/aws/{account}/*/role/{role}"], ["{role}"]}, {["/ns/prod/sa/admin"], ["admin"]}},
            # two layouts sharing a namespace under different names
            {@aws, {["/ns/{namespace}/sa/{sa}"], ["{namespace}/{sa}"]}},
            {@aws, {["/ns/*/sa/{sa}"], ["{sa}"]}},
            # within one path, two captures in the same position
            {{["/{a}/{b}"], ["{a}"]}, {["/{a}/{b}/x"], ["{b}"]}}
          ] do
        assert compile_error([left, right]) =~ "can produce the same policy name"
      end

      # Both in one entry: regrouping is no fix, so the message must not suggest it.
      message = compile_error([{["/{a}/{b}"], ["{a}", "{b}"]}])
      assert message =~ ~s("{a}" in paths[0] and "{b}" in paths[0] can produce the same)
      refute message =~ "under one entry"
    end

    test "accepts templates kept apart by fixed text" do
      assert {:ok, _} =
               SPIFFE.compile(@domain, [
                 @aws,
                 {["/ns/{namespace}/sa/{sa}"], ["k8s:{namespace}/{sa}", "k8s:{sa}"]},
                 {["/pinned/admin"], ["pinned:admin"]}
               ])
    end

    test "accepts several patterns sharing one entry's policy names" do
      assert {:ok, %SPIFFE{entries: [{[_, _], _}]}} =
               SPIFFE.compile(@domain, [
                 {["/aws/{account}/{region}/role/{role}", "/aws/{account}/role/{role}"],
                  ["{account}/{role}", "{role}"]}
               ])
    end

    test "refuses the same template text in two entries, whatever the captures are called" do
      # Capture names mean nothing to the proxy, so a shared "{role}" is two layouts in
      # one namespace: a service account named sre would get the AWS sre policy.
      message =
        compile_error([
          {["/aws/{account}/*/role/{role}"], ["{role}"]},
          {["/ns/*/sa/{role}"], ["{role}"]}
        ])

      assert message =~ ~s("{role}" in paths[0] and "{role}" in paths[1])
      assert message =~ "list their patterns under one entry"
    end

    test "refuses grouping patterns whose fixed segments differ" do
      # Otherwise one entry could join AWS roles and Kubernetes service accounts under
      # "{role}", which the template check refuses across entries.
      for patterns <- [
            ["/aws/{account}/role/{role}", "/k8s/{ns}/sa/{role}"],
            ["/aws/{account}/role/{role}", "/aws/{account}/sso/{role}"],
            ["/aws/role/{role}", "/role/aws/{role}"]
          ] do
        [first, second] = patterns

        assert compile_error([{patterns, ["{role}"]}]) =~
                 ~s(paths[0] groups patterns #{inspect(first)} and #{inspect(second)})
      end
    end

    test "needs every template to be fillable from every pattern in its entry" do
      message =
        compile_error([
          {["/aws/{account}/{region}/role/{role}", "/aws/{account}/role/{role}"],
           ["{region}/{role}"]}
        ])

      assert message =~ ~s(pattern "/aws/{account}/role/{role}" does not capture)
    end

    test "refuses two patterns that can match one ID, in one entry or across entries" do
      for entries <- [
            # pinning the account in one pattern overlaps the general one
            [
              {["/aws/111122223333/*/role/{role}"], ["prod:{role}"]},
              {["/aws/{account}/*/role/{role}"], ["{account}/{role}"]}
            ],
            [{["/{a}/x", "/x/{a}"], ["{a}"]}],
            [{["/aws/{a}"], ["{a}"]}, {["/aws/{b}"], ["k8s:{b}"]}],
            [{["/aws/{a}", "/aws/{a}"], ["{a}"]}]
          ] do
        assert compile_error(entries) =~ "can both match one ID"
      end

      assert compile_error([@aws, {["/k8s/{a}"], ["k8s:{a}"]}, {["/k8s/{b}"], ["x:{b}"]}]) =~
               ~s(pattern "/k8s/{a}" in paths[1] and "/k8s/{b}" in paths[2] can both match)
    end

    test "accepts patterns kept apart by a fixed segment or by length" do
      assert {:ok, _} =
               SPIFFE.compile(@domain, [
                 {["/aws/{account}/{region}/role/{role}", "/aws/{account}/role/{role}"],
                  ["{account}/{role}", "{role}"]},
                 {["/k8s/*/sa/{sa}"], ["k8s:{sa}"]}
               ])
    end

    test "names the failing entry by index" do
      assert compile_error([@aws, {["role/{role}"], ["k8s:{role}"]}]) =~
               ~s(paths[1] pattern "role/{role}" must start with /)

      assert compile_error([@aws, {["/k8s/{sa}"], ["{sa"]}]) =~
               ~s(paths[1] policy_names entry "{sa")
    end

    test "never treats . or .. as something a capture could produce" do
      # No SPIFFE segment can be . or .., so these templates cannot collide.
      assert {:ok, _} =
               SPIFFE.compile(@domain, [
                 {["/a/{x}"], ["x:{x}"]},
                 {["/b/fixed"], ["x:."]},
                 {["/c/fixed"], ["x:.."]}
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
      refute SPIFFE.produces?(spiffe, ".")
      refute SPIFFE.produces?(spiffe, "..")
      refute SPIFFE.produces?(spiffe, "111122223333/..")
    end

    test "matches fixed text exactly" do
      spiffe = spiffe!([{["/ns/*/sa/{sa}"], ["k8s:{sa}"]}])

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
      spiffe = spiffe!([{["/aws/{account}/*/role/{role}"], ["{role}", "{account}/{role}"]}])

      assert {:ok, ["sre", "111122223333/sre"]} =
               SPIFFE.roles(spiffe, @prefix <> "/aws/111122223333/eu-west-1/role/sre")
    end

    test "uses only the matched path's own templates" do
      spiffe = spiffe!([@aws, {["/ns/*/sa/{sa}"], ["k8s:{sa}"]}])

      assert {:ok, ["k8s:sre"]} = SPIFFE.roles(spiffe, @prefix <> "/ns/default/sa/sre")
    end

    test "maps alternative layouts in one entry to the same names" do
      spiffe =
        spiffe!([
          {["/aws/{account}/{region}/role/{role}", "/aws/{account}/role/{role}"],
           ["{account}/{role}", "{role}"]}
        ])

      assert {:ok, ["1111/sre", "sre"]} =
               SPIFFE.roles(spiffe, @prefix <> "/aws/1111/eu-west-1/role/sre")

      assert {:ok, ["1111/sre", "sre"]} = SPIFFE.roles(spiffe, @prefix <> "/aws/1111/role/sre")
    end

    test "works for layouts with no account at all" do
      spiffe = spiffe!([{["/ns/{namespace}/sa/{sa}"], ["{namespace}/{sa}", "{sa}"]}])

      assert {:ok, ["payments/ingest", "ingest"]} =
               SPIFFE.roles(spiffe, @prefix <> "/ns/payments/sa/ingest")
    end

    test "matches literals exactly, case included, and segment counts exactly" do
      spiffe = spiffe!([{["/aws/111122223333/*/role/{role}"], ["{role}"]}])

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

    test "yields no names for another trust domain or an invalid ID" do
      spiffe = spiffe!([{["/role/{role}"], ["{role}"]}])

      assert {:none, message} = SPIFFE.roles(spiffe, "spiffe://other.example.com/role/sre")
      assert message =~ "other.example.com"
      assert {:none, "is not a valid SPIFFE ID"} = SPIFFE.roles(spiffe, @prefix <> "/role/../sre")
      assert {:none, "is not a valid SPIFFE ID"} = SPIFFE.roles(spiffe, "sre")
    end
  end
end
