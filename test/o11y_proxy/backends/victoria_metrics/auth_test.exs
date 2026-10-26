defmodule O11yProxy.Backends.VictoriaMetrics.AuthTest do
  @moduledoc """
  The adapter's outbound credentials, against a `Req` function plug instead of a real
  VictoriaMetrics, so it runs in CI. Not async: the plug is installed through application
  env.
  """

  use ExUnit.Case, async: false

  alias O11yProxy.Backends.VictoriaMetrics

  @moduletag :tmp_dir

  setup do
    test = self()

    Application.put_env(:o11y_proxy, :victoriametrics_req_options,
      plug: fn conn ->
        send(test, {:request, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"status" => "success", "data" => []})
      end
    )

    on_exit(fn -> Application.delete_env(:o11y_proxy, :victoriametrics_req_options) end)
  end

  defp init(overrides) do
    %{
      url: "http://vm.test",
      base_path: "",
      auth: "none",
      username: "",
      password: "",
      token: "",
      token_file: "",
      allow_raw: false,
      timeout_ms: 1_000,
      summary_points: 50,
      full_points: 500
    }
    |> Map.merge(Map.new(overrides))
    |> VictoriaMetrics.init()
  end

  test "bearer_file sends the file's token, and the new one once it is rotated",
       %{tmp_dir: dir} do
    path = Path.join(dir, "token")
    File.write!(path, "first-token\n")
    {:ok, state} = init(auth: "bearer_file", token_file: path)

    assert {:ok, _} = VictoriaMetrics.schema(state)
    assert_received {:request, "/api/v1/labels", ["Bearer first-token"]}

    File.write!(path, "second-token\n")

    assert {:ok, _} = VictoriaMetrics.schema(state)
    assert_received {:request, "/api/v1/labels", ["Bearer second-token"]}
  end

  test "bearer_file with no readable token sends nothing, and says why", %{tmp_dir: dir} do
    {:ok, state} = init(auth: "bearer_file", token_file: Path.join(dir, "not-yet-written"))

    assert {:error, {:victoriametrics_unreachable, message}} = VictoriaMetrics.schema(state)
    assert message =~ "no token to send: the token file could not be read (enoent)"

    assert {:error, {:victoriametrics_unreachable, _}} = VictoriaMetrics.health(state)
    refute_received {:request, _, _}
  end

  test "health sends the credential too", %{tmp_dir: dir} do
    path = Path.join(dir, "token")
    File.write!(path, "health-token")
    {:ok, state} = init(auth: "bearer_file", token_file: path)

    assert :ok = VictoriaMetrics.health(state)
    assert_received {:request, "/health", ["Bearer health-token"]}

    {:ok, state} = init(auth: "bearer", token: "static")
    assert :ok = VictoriaMetrics.health(state)
    assert_received {:request, "/health", ["Bearer static"]}
  end

  test "bearer_file without a token_file is refused at init" do
    assert {:error, message} = init(auth: "bearer_file")
    assert message =~ "auth: bearer_file needs token_file"
  end

  test "auth: none sends no authorization header" do
    {:ok, state} = init([])

    assert {:ok, _} = VictoriaMetrics.schema(state)
    assert_received {:request, "/api/v1/labels", []}
  end
end
