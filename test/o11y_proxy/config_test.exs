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
    assert config.defaults == %{limit: 25, max_window: "3d", timeout: "10s"}
    assert [%Config.Source{} = source] = config.sources
    assert source.name == "app_logs"
    assert source.backend == O11yProxy.Test.FakeBackend
    assert source.signal == :logs
    assert source.opts == %{table: "otel_logs", allow_raw: true}
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
    assert defaults == %{limit: 50, max_window: "7d", timeout: "30s"}
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
end
