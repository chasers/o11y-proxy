defmodule O11yProxy.Plugs.Auth do
  @moduledoc """
  The HTTP side of `O11yProxy.Auth`: hands the request headers to the configured mode's
  implementation and assigns the resulting `:caller`, or answers 401/403/503 and halts.

  `/healthz` and `/openapi.json` are always open, in every mode. A liveness probe has no
  credentials to send, and an agent reads the spec to learn how to authenticate in the
  first place. Neither returns data from a source.
  """

  import Plug.Conn

  @open_paths ["/healthz", "/openapi.json"]

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: path} = conn, _opts) when path in @open_paths, do: conn

  def call(conn, _opts) do
    mode = Application.get_env(:o11y_proxy, :auth, :none)

    case O11yProxy.Auth.authenticate(mode, conn.req_headers) do
      {:ok, caller} -> assign(conn, :caller, caller)
      {:error, {kind, message}} -> reject(conn, kind, message)
    end
  end

  defp reject(conn, :unauthorized, message) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> send_error(401, "unauthorized", message)
  end

  defp reject(conn, :forbidden, message), do: send_error(conn, 403, "forbidden", message)

  defp reject(conn, :unavailable, message) do
    conn
    |> put_resp_header("retry-after", "5")
    |> send_error(503, "auth_unavailable", message)
  end

  defp send_error(conn, status, error, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error, message: message}))
    |> halt()
  end
end
