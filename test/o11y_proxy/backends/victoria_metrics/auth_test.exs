defmodule O11yProxy.Backends.VictoriaMetrics.AuthTest do
  @moduledoc """
  The adapter's outbound credentials, against a `Req` function plug instead of a real
  VictoriaMetrics, so it runs in CI. Not async: the plug is installed through application
  env.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias O11yProxy.Backends.VictoriaMetrics

  @moduletag :tmp_dir
  @moduletag :capture_log

  # Serves every path with an empty success, or with `labels` for the label-names call,
  # and reports each request's path and authorization header to the test.
  defp serve(labels \\ [], on_labels \\ fn -> :ok end) do
    test = self()

    Application.put_env(:o11y_proxy, :victoriametrics_req_options,
      plug: fn conn ->
        send(test, {:request, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})

        if conn.request_path == "/api/v1/labels" do
          on_labels.()
          Req.Test.json(conn, %{"status" => "success", "data" => labels})
        else
          Req.Test.json(conn, %{"status" => "success", "data" => []})
        end
      end
    )
  end

  setup do
    serve()
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

  defp token_file(dir, token) do
    path = Path.join(dir, "token")
    File.write!(path, token)
    path
  end

  test "bearer_file sends the file's token, and the new one once it is rotated",
       %{tmp_dir: dir} do
    path = token_file(dir, "first-token\n")
    {:ok, state} = init(auth: "bearer_file", token_file: path)

    assert {:ok, _} = VictoriaMetrics.schema(state)
    assert_received {:request, "/api/v1/labels", ["Bearer first-token"]}

    File.write!(path, "second-token\n")

    assert {:ok, _} = VictoriaMetrics.schema(state)
    assert_received {:request, "/api/v1/labels", ["Bearer second-token"]}
  end

  test "one schema call sends one token, even if the file is rotated partway through",
       %{tmp_dir: dir} do
    path = token_file(dir, "before")
    serve(["service", "env"], fn -> File.write!(path, "after") end)
    {:ok, state} = init(auth: "bearer_file", token_file: path)

    assert {:ok, %{fields: [_, _]}} = VictoriaMetrics.schema(state)

    assert_received {:request, "/api/v1/labels", ["Bearer before"]}
    assert_received {:request, "/api/v1/label/service/values", ["Bearer before"]}
    assert_received {:request, "/api/v1/label/env/values", ["Bearer before"]}
  end

  test "a token that may turn up is credential_unavailable, and nothing is sent",
       %{tmp_dir: dir} do
    {:ok, state} = init(auth: "bearer_file", token_file: Path.join(dir, "not-yet-written"))

    assert {:error, {:credential_unavailable, message}} = VictoriaMetrics.schema(state)
    assert message == "the token file could not be read: no such file or directory"

    assert {:error, {:credential_unavailable, _}} = VictoriaMetrics.health(state)
    refute_received {:request, _, _}
  end

  test "a file that is not a token is credential_invalid", %{tmp_dir: dir} do
    {:ok, state} = init(auth: "bearer_file", token_file: token_file(dir, ~s({"token": "x"})))

    assert {:error, {:credential_invalid, message}} = VictoriaMetrics.schema(state)
    assert message =~ "does not hold a single bearer token"
    refute_received {:request, _, _}
  end

  test "health sends the credential too", %{tmp_dir: dir} do
    {:ok, state} = init(auth: "bearer_file", token_file: token_file(dir, "health-token"))

    assert :ok = VictoriaMetrics.health(state)
    assert_received {:request, "/health", ["Bearer health-token"]}

    {:ok, state} = init(auth: "bearer", token: "static")
    assert :ok = VictoriaMetrics.health(state)
    assert_received {:request, "/health", ["Bearer static"]}
  end

  test "test-only req_options cannot replace the credential", %{tmp_dir: dir} do
    Application.put_env(
      :o11y_proxy,
      :victoriametrics_req_options,
      Keyword.put(
        Application.get_env(:o11y_proxy, :victoriametrics_req_options),
        :auth,
        {:bearer, "override"}
      )
    )

    {:ok, state} = init(auth: "bearer_file", token_file: token_file(dir, "real"))

    assert :ok = VictoriaMetrics.health(state)
    assert_received {:request, "/health", ["Bearer real"]}
  end

  test "auth: none sends no authorization header" do
    {:ok, state} = init([])

    assert {:ok, _} = VictoriaMetrics.schema(state)
    assert_received {:request, "/api/v1/labels", []}
  end

  describe "init" do
    test "bearer_file needs a token_file" do
      assert {:error, message} = init(auth: "bearer_file")
      assert message =~ "auth: bearer_file needs token_file"
    end

    test "refuses any credential field the chosen mode would ignore", %{tmp_dir: dir} do
      path = token_file(dir, "t")

      for {overrides, message} <- [
            {[auth: "bearer_file", token_file: path, token: "stale"],
             "auth: bearer_file does not read token"},
            {[auth: "bearer_file", token_file: path, password: "old"],
             "auth: bearer_file does not read password"},
            {[auth: "bearer", token: "t", token_file: path],
             "auth: bearer does not read token_file"},
            {[auth: "basic", username: "u", token: "t"], "auth: basic does not read token"},
            {[auth: "none", username: "u", token_file: path],
             "auth: none does not read username, token_file"}
          ] do
        assert {:error, refused} = init(overrides)
        assert refused =~ message
      end

      assert {:ok, _} = init(auth: "basic", username: "u", password: "p")
    end

    test "starts with an unreadable token_file, but logs a warning", %{tmp_dir: dir} do
      path = Path.join(dir, "not-yet-written")

      log =
        capture_log(fn ->
          assert {:ok, _} = init(auth: "bearer_file", token_file: path)
        end)

      assert log =~ "victoriametrics token_file #{path}"
      assert log =~ "no such file or directory"

      assert log =~ "fail until whatever writes the file has written it"

      log = capture_log(fn -> init(auth: "bearer_file", token_file: token_file(dir, "a b")) end)
      assert log =~ "fail until the file or the path in config is fixed"

      log = capture_log(fn -> init(auth: "bearer_file", token_file: token_file(dir, "ok")) end)
      refute log =~ "token_file"
    end
  end

  describe "a credential the backend refuses" do
    setup do
      test = self()

      Application.put_env(:o11y_proxy, :victoriametrics_req_options,
        plug: fn conn ->
          send(test, {:request, conn.request_path})
          status = if conn.request_path == "/health", do: 403, else: 401
          Plug.Conn.send_resp(conn, status, ~s({"error": "token expired", "claims": "secret"}))
        end
      )
    end

    test "is credential_rejected, without the body, and logged", %{tmp_dir: dir} do
      {:ok, state} = init(auth: "bearer_file", token_file: token_file(dir, "expired"))

      log =
        capture_log(fn ->
          assert {:error, {:credential_rejected, "HTTP 401"}} = VictoriaMetrics.schema(state)
          assert {:error, {:credential_rejected, "HTTP 403"}} = VictoriaMetrics.health(state)
        end)

      assert log =~ "refused the proxy's credential with HTTP 401"
      refute log =~ "secret"
    end
  end

  test "a token file that goes bad after boot is logged with its path", %{tmp_dir: dir} do
    path = token_file(dir, "fine")
    {:ok, state} = init(auth: "bearer_file", token_file: path)
    File.write!(path, ~s({"not": "a token"}))

    log = capture_log(fn -> assert {:error, _} = VictoriaMetrics.schema(state) end)
    assert log =~ "victoriametrics token_file #{path}: the token file does not hold"
  end
end
