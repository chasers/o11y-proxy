defmodule O11yProxy.ConfigTest do
  use ExUnit.Case, async: false

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
    assert config.server == %{port: 4001, auth: :none}
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

    assert server == %{port: 4000, auth: :none}

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
end
