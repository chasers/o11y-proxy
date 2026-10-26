defmodule O11yProxy.ConfigTest do
  use ExUnit.Case, async: false

  alias O11yProxy.Auth.SPIFFE
  alias O11yProxy.Config

  setup do
    Application.put_env(:o11y_proxy, :backends, %{"fake" => O11yProxy.Test.FakeBackend})
    on_exit(fn -> Application.delete_env(:o11y_proxy, :backends) end)
    :ok
  end

  @tag :tmp_dir
  test "loads server, defaults, and sources with env interpolation", %{tmp_dir: dir} do
    System.put_env("O11Y_TEST_TABLE", "otel_logs")

    path = Path.join(dir, "o11y.yaml")

    File.write!(path, """
    server:
      port: 4001
      auth: none

    defaults:
      limit: 25
      max_window: 3d
      timeout: 10s

    sources:
      - name: app_logs
        backend: fake
        signal: logs
        table: ${O11Y_TEST_TABLE}
        allow_raw: true
    """)

    assert {:ok, %Config{} = config} = Config.load(path: path)

    assert config.server == %{
             port: 4001,
             bind: {127, 0, 0, 1},
             auth: :none,
             oidc: nil,
             distribution: true
           }

    assert %{limit: 25, max_window: "3d", timeout: "10s"} = config.defaults
    assert [%Config.Source{} = source] = config.sources
    assert source.name == "app_logs"
    assert source.backend == O11yProxy.Test.FakeBackend
    assert source.signal == :logs
    # The adapter's own config_schema/0 defaults are applied too, so assert on what this
    # test is actually about (env interpolation + declared values) rather than pinning
    # every default the fixture backend happens to declare.
    assert %{table: "otel_logs", allow_raw: true} = source.opts
  after
    System.delete_env("O11Y_TEST_TABLE")
  end

  @tag :tmp_dir
  test "applies documented defaults when server/defaults/sources are omitted", %{tmp_dir: dir} do
    path = Path.join(dir, "o11y.yaml")
    File.write!(path, "sources: []\n")

    assert {:ok, %Config{server: server, defaults: defaults, sources: []}} =
             Config.load(path: path)

    assert server == %{
             port: 4000,
             bind: {127, 0, 0, 1},
             auth: :none,
             oidc: nil,
             distribution: true
           }

    assert defaults == %{
             limit: 50,
             max_window: "7d",
             timeout: "30s",
             max_bytes: 64_000,
             redact_keys: []
           }
  end

  @tag :tmp_dir
  test "a missing referenced env var fails to load, never silently blank", %{tmp_dir: dir} do
    path = Path.join(dir, "o11y.yaml")

    File.write!(path, """
    sources:
      - name: app_logs
        backend: fake
        signal: logs
        table: ${O11Y_TEST_DEFINITELY_UNSET}
    """)

    assert {:error, {:missing_env_var, "O11Y_TEST_DEFINITELY_UNSET"}} = Config.load(path: path)
  end

  @tag :tmp_dir
  test "an unknown backend name fails at load with a precise reason", %{tmp_dir: dir} do
    path = Path.join(dir, "o11y.yaml")

    File.write!(path, """
    sources:
      - name: app_logs
        backend: not_a_real_backend
        signal: logs
    """)

    assert {:error, {:unknown_backend, "not_a_real_backend"}} = Config.load(path: path)
  end

  @tag :tmp_dir
  test "a source config that fails its adapter's own schema fails at load", %{tmp_dir: dir} do
    path = Path.join(dir, "o11y.yaml")

    File.write!(path, """
    sources:
      - name: app_logs
        backend: fake
        signal: logs
        allow_raw: true
    """)

    assert {:error, {:invalid_source_config, "app_logs", message}} = Config.load(path: path)
    assert message =~ "table"
  end

  @tag :tmp_dir
  test "an invalid server.auth value fails at load", %{tmp_dir: dir} do
    path = Path.join(dir, "o11y.yaml")

    File.write!(path, """
    server:
      auth: maybe
    sources: []
    """)

    assert {:error, {:invalid_block, :server, _message}} = Config.load(path: path)
  end

  test "no config file anywhere is a structured error, not a crash" do
    assert {:error, {:no_config_file, _candidates}} =
             Config.load(path: "/nonexistent/definitely/not/here.yaml")
  end

  describe "server.bind, server.oidc and policies" do
    @source_block """
    sources:
      - name: app_logs
        backend: fake
        signal: logs
        table: otel_logs
        allow_raw: false
    """

    @oidc_block """
      oidc:
        issuer: https://issuer.example.com
        audience: o11y-proxy
        role_claim: o11y.role
    """

    @policy_block """
    policies:
      support:
        sources: [app_logs]
        max_lookback: 1d
        constraints:
          - field: project
            require: true
            allowed_claim: o11y.projects
    """

    defp load_yaml(dir, yaml) do
      path = Path.join(dir, "o11y.yaml")
      File.write!(path, yaml)
      Config.load(path: path)
    end

    defp invalid!(dir, yaml) do
      assert {:error, {:invalid_block, block, message} = reason} = load_yaml(dir, yaml)
      assert is_binary(Config.format_error(reason))
      {block, message}
    end

    @tag :tmp_dir
    test "loads auth: oidc with its block and policies", %{tmp_dir: dir} do
      yaml =
        "server:\n  bind: 0.0.0.0\n  auth: oidc\n" <>
          @oidc_block <> @source_block <> @policy_block

      assert {:ok, config} = load_yaml(dir, yaml)
      assert config.server.bind == {0, 0, 0, 0}
      assert config.server.auth == :oidc

      assert %{
               issuer: "https://issuer.example.com",
               audience: ["o11y-proxy"],
               identity_claim: "sub",
               role_claim: "o11y.role",
               jwks_refresh_seconds: 300,
               leeway_seconds: 60
             } = config.server.oidc

      assert %{"support" => %O11yProxy.Policy{max_lookback_seconds: 86_400}} = config.policies
    end

    @tag :tmp_dir
    test "accepts an IPv6 bind", %{tmp_dir: dir} do
      assert {:ok, config} = load_yaml(dir, "server:\n  bind: \"::1\"\n")
      assert config.server.bind == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    @tag :tmp_dir
    test "refuses a bind that is not an IP address", %{tmp_dir: dir} do
      assert {:server, message} = invalid!(dir, "server:\n  bind: localhost\n")
      assert message =~ "not an IP address"
    end

    @tag :tmp_dir
    test "refuses auth: none on a non-loopback bind", %{tmp_dir: dir} do
      assert {:server, message} = invalid!(dir, "server:\n  bind: 0.0.0.0\n")
      assert message =~ "needs auth: token or auth: oidc"
    end

    @tag :tmp_dir
    test "allows auth: token on a non-loopback bind", %{tmp_dir: dir} do
      assert {:ok, _} = load_yaml(dir, "server:\n  bind: 0.0.0.0\n  auth: token\n")
    end

    @tag :tmp_dir
    test "refuses auth: oidc with no oidc block", %{tmp_dir: dir} do
      assert {:server, message} =
               invalid!(dir, "server:\n  auth: oidc\n" <> @source_block <> @policy_block)

      assert message =~ "needs a server.oidc block"
    end

    @tag :tmp_dir
    test "refuses an oidc block when auth is not oidc", %{tmp_dir: dir} do
      assert {:server, message} = invalid!(dir, "server:\n  auth: token\n" <> @oidc_block)
      assert message =~ "set auth: oidc"
    end

    @tag :tmp_dir
    test "refuses policies when auth is not oidc, since they would not be enforced",
         %{tmp_dir: dir} do
      assert {:policies, message} =
               invalid!(dir, "server:\n  auth: token\n" <> @source_block <> @policy_block)

      assert message =~ "only enforced for auth: oidc"
    end

    @tag :tmp_dir
    test "refuses auth: oidc with no policies", %{tmp_dir: dir} do
      assert {:policies, message} = invalid!(dir, "server:\n  auth: oidc\n" <> @oidc_block)
      assert message =~ "at least one policy"
    end

    @tag :tmp_dir
    test "refuses an oidc block missing its required keys", %{tmp_dir: dir} do
      yaml = "server:\n  auth: oidc\n  oidc:\n    issuer: https://issuer.example.com\n"
      assert {"server.oidc", message} = invalid!(dir, yaml)
      assert message =~ "audience"
    end

    @tag :tmp_dir
    test "refuses an unsupported or symmetric algorithm", %{tmp_dir: dir} do
      yaml =
        "server:\n  auth: oidc\n" <>
          @oidc_block <> "    algorithms: [HS256]\n" <> @source_block <> @policy_block

      assert {"server.oidc", message} = invalid!(dir, yaml)
      assert message =~ "algorithms"
    end

    @tag :tmp_dir
    test "needs a role_claim or a default_policy", %{tmp_dir: dir} do
      yaml =
        "server:\n  auth: oidc\n  oidc:\n    issuer: https://i.example\n    audience: x\n" <>
          @source_block <> @policy_block

      assert {"server.oidc", message} = invalid!(dir, yaml)
      assert message =~ "role_claim, default_policy, or both"
    end

    @tag :tmp_dir
    test "refuses a default_policy that is not defined", %{tmp_dir: dir} do
      yaml =
        "server:\n  auth: oidc\n" <>
          @oidc_block <>
          "    default_policy: viewer\n" <>
          @source_block <> @policy_block

      assert {"server.oidc", message} = invalid!(dir, yaml)
      assert message =~ ~s(default_policy "viewer" is not defined)
      assert message =~ "support"
    end

    @spiffe_oidc_block """
      oidc:
        issuer: https://mint.example.com
        audience: o11y-proxy
        role_claim: sub
        spiffe:
          trust_domain: mint.example.com
          paths:
            - patterns: ["/aws/{account}/*/role/{role}"]
              policy_names: ["{account}/{role}", "{role}"]
    """

    @spiffe_policy_block """
    policies:
      "111122223333/sre":
        sources: "*"
      sre:
        sources: [app_logs]
    """

    defp spiffe_yaml(oidc_block, policy_block \\ @spiffe_policy_block),
      do: "server:\n  auth: oidc\n" <> oidc_block <> @source_block <> policy_block

    @tag :tmp_dir
    test "compiles a spiffe block, and accepts account-pinned policy names", %{tmp_dir: dir} do
      assert {:ok, config} = load_yaml(dir, spiffe_yaml(@spiffe_oidc_block))

      assert %SPIFFE{trust_domain: "mint.example.com", entries: [_]} =
               config.server.oidc.spiffe

      assert %{"111122223333/sre" => _, "sre" => _} = config.policies
    end

    @tag :tmp_dir
    test "leaves spiffe out of the oidc config when it is not set", %{tmp_dir: dir} do
      yaml = "server:\n  auth: oidc\n" <> @oidc_block <> @source_block <> @policy_block
      assert {:ok, config} = load_yaml(dir, yaml)
      refute Map.has_key?(config.server.oidc, :spiffe)
    end

    @tag :tmp_dir
    test "refuses an empty spiffe block instead of treating it as unset", %{tmp_dir: dir} do
      emptied = String.replace(@spiffe_oidc_block, ~r/      trust_domain:.*\z/s, "")
      assert emptied =~ ~r/spiffe:\n\z/

      assert {:error, {:invalid_block_shape, "server.oidc.spiffe", nil}} =
               load_yaml(dir, spiffe_yaml(emptied))
    end

    @tag :tmp_dir
    test "refuses a policy name using a {name} its pattern does not capture", %{tmp_dir: dir} do
      yaml =
        @spiffe_oidc_block
        |> String.replace(~s("{account}/{role}", "{role}"), ~s("{region}/{role}"))
        |> spiffe_yaml()

      assert {"server.oidc.spiffe", message} = invalid!(dir, yaml)
      assert message =~ "does not capture"
    end

    @tag :tmp_dir
    test "refuses a policy name that collides with another layout's", %{tmp_dir: dir} do
      yaml =
        spiffe_yaml(
          @spiffe_oidc_block <>
            "        - patterns: [\"/ns/*/sa/{sa}\"]\n" <>
            "          policy_names: [\"{sa}\"]\n"
        )

      assert {"server.oidc.spiffe", message} = invalid!(dir, yaml)
      assert message =~ "can produce the same policy name"
    end

    @tag :tmp_dir
    test "refuses unknown keys, and missing paths, patterns or policy_names", %{tmp_dir: dir} do
      for {yaml, block, complaint} <- [
            {@spiffe_oidc_block <> "      region: x\n", "server.oidc.spiffe", "region"},
            {String.replace(@spiffe_oidc_block, ~r/      paths:.*\z/s, "      x: 1\n"),
             "server.oidc.spiffe", "paths"},
            {String.replace(@spiffe_oidc_block, "- patterns: [", "- patern: ["),
             "server.oidc.spiffe.paths[0]", "patern"},
            {String.replace(@spiffe_oidc_block, ~r/\n          policy_names:.*\n/, "\n"),
             "server.oidc.spiffe.paths[0]", "policy_names"}
          ] do
        assert {^block, message} = invalid!(dir, spiffe_yaml(yaml))
        assert message =~ complaint
      end
    end

    @tag :tmp_dir
    test "refuses spiffe without a role_claim, before the generic message", %{tmp_dir: dir} do
      no_claim = String.replace(@spiffe_oidc_block, "    role_claim: sub\n", "")

      for oidc <- [no_claim, no_claim <> "    default_policy: sre\n"] do
        assert {"server.oidc", message} = invalid!(dir, spiffe_yaml(oidc))
        assert message =~ "set role_claim (usually sub)"
      end
    end

    @tag :tmp_dir
    test "refuses a policy no spiffe template can produce", %{tmp_dir: dir} do
      policies = @spiffe_policy_block <> "  \"111122223333:sre\":\n    sources: [app_logs]\n"

      assert {:policies, message} = invalid!(dir, spiffe_yaml(@spiffe_oidc_block, policies))
      assert message =~ ~s("111122223333:sre")
      refute message =~ ~s("sre",)
    end

    @tag :tmp_dir
    test "lets the default_policy be a name no template produces", %{tmp_dir: dir} do
      policies = @spiffe_policy_block <> "  \"fallback policy\":\n    sources: [app_logs]\n"
      oidc = @spiffe_oidc_block <> "    default_policy: fallback policy\n"

      assert {:ok, _} = load_yaml(dir, spiffe_yaml(oidc, policies))
    end

    @tag :tmp_dir
    test "refuses a policy that names an unconfigured source", %{tmp_dir: dir} do
      yaml =
        "server:\n  auth: oidc\n" <>
          @oidc_block <>
          @source_block <>
          "policies:\n  sre:\n    sources: [app_logz]\n"

      assert {"policies.sre", message} = invalid!(dir, yaml)
      assert message =~ ~s(unknown source "app_logz")
    end
  end

  describe "format_error/1" do
    # These strings are the whole first-run experience for someone who downloaded a
    # single-file binary and ran it in an empty directory. They must say what broke and
    # what to do — never leak a raw Elixir tuple.
    test "a missing config file explains where it looked and how to point elsewhere" do
      message = Config.format_error({:no_config_file, ["./o11y.yaml", "~/.config/x.yaml"]})

      assert message =~ "No config file found"
      assert message =~ "./o11y.yaml"
      assert message =~ "O11Y_PROXY_CONFIG"
      assert message =~ "sources: []"
    end

    test "a YAML syntax error names the file, line and column" do
      error = %YamlElixir.ParsingError{line: 3, column: 2, type: :x, message: "bad token"}
      message = Config.format_error({:invalid_yaml, "/tmp/o11y.yaml", error})

      assert message =~ "/tmp/o11y.yaml"
      assert message =~ "line 3, column 2"
      assert message =~ "bad token"
    end

    test "a missing env var names the variable" do
      message = Config.format_error({:missing_env_var, "SENTRY_AUTH_TOKEN"})

      assert message =~ "${SENTRY_AUTH_TOKEN}"
      assert message =~ "export SENTRY_AUTH_TOKEN"
    end

    test "a misconfigured source names the source and the adapter's own complaint" do
      message = Config.format_error({:invalid_source_config, "app_logs", "required :url not set"})

      assert message =~ ~s(Source "app_logs")
      assert message =~ "required :url not set"
    end

    test "an unknown backend lists the ones that exist" do
      message = Config.format_error({:unknown_backend, "postgres"})

      assert message =~ ~s(Unknown backend "postgres")
      assert message =~ "clickhouse"
      assert message =~ "sentry"
      assert message =~ "victoriametrics"
    end

    test "an invalid signal lists the valid ones" do
      message = Config.format_error({:invalid_signal, "lgos"})

      assert message =~ "lgos"
      assert message =~ "logs"
      assert message =~ "metrics"
    end

    test "a malformed source entry shows the required keys" do
      message = Config.format_error({:invalid_source_shape, %{"name" => "x"}})

      assert message =~ "name"
      assert message =~ "backend"
      assert message =~ "signal"
    end

    test "an unrecognized reason still returns a string rather than raising" do
      assert is_binary(Config.format_error({:something_new, :entirely}))
    end
  end

  describe "the configs this repo ships as documentation" do
    # These are what someone copies. A config that no longer validates is a worse bug than
    # a stale sentence, because it fails at *their* boot rather than in review — and the
    # per-backend `config_schema/0` they are written against is free to change underneath
    # them. The `setup` above swaps the backend registry for the fake one, so restore it.
    setup do
      Application.delete_env(:o11y_proxy, :backends)
      :ok
    end

    for path <- [
          "examples/cloudwatch-s3/o11y.yaml",
          "examples/oidc-rbac/o11y.yaml",
          "docker/o11y.yaml"
        ] do
      test "#{path} validates against the real backend registry" do
        assert {:ok, %{sources: [_ | _] = sources}} = Config.load(path: unquote(path))
        assert Enum.all?(sources, &is_atom(&1.backend))
      end
    end

    # The SPIFFE snippets are fragments, not whole configs, so they are checked at the
    # level they are written: YAML that parses, a spiffe block that compiles, and policies
    # it can actually reach. An unquoted `{` in a flow sequence once shipped here.
    test "every spiffe: snippet in docs/authentication.md parses and compiles" do
      snippets =
        ~r/```yaml\n(.*?)```/s
        |> Regex.scan(File.read!("docs/authentication.md"), capture: :all_but_first)
        |> List.flatten()
        |> Enum.filter(&(&1 =~ "spiffe:"))

      assert [_, _, _ | _] = snippets

      for snippet <- snippets do
        assert {:ok, yaml} = YamlElixir.read_from_string(snippet),
               "this snippet is not valid YAML:\n#{snippet}"

        spiffe = get_in(yaml, ["server", "oidc", "spiffe"]) || yaml["spiffe"]
        paths = for path <- spiffe["paths"], do: {path["patterns"], path["policy_names"]}

        assert {:ok, compiled} = SPIFFE.compile(spiffe["trust_domain"], paths),
               "this snippet's spiffe block does not compile:\n#{snippet}"

        for name <- Map.keys(yaml["policies"] || %{}) do
          assert SPIFFE.produces?(compiled, name),
                 "policy #{inspect(name)} is unreachable in:\n#{snippet}"
        end
      end
    end
  end
end
