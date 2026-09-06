defmodule O11yProxy.Plugs.Auth do
  @moduledoc """
  No-op by default (`server.auth: none`) — assigns the singleton local `Caller`. Token
  auth is the shared-deployment seam: set `server.auth: token` and `O11Y_PROXY_TOKEN`;
  requests then need a matching `Authorization: Bearer <token>` header. See
  "Shared-ready seams" in `.plans/04-cross-cutting.md`.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:o11y_proxy, :auth, :none) do
      :none -> assign(conn, :caller, O11yProxy.Caller.local())
      :token -> authenticate(conn)
    end
  end

  defp authenticate(conn) do
    expected = System.get_env("O11Y_PROXY_TOKEN")

    with [header] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- header,
         true <- is_binary(expected) and Plug.Crypto.secure_compare(token, expected) do
      assign(conn, :caller, O11yProxy.Caller.local())
    else
      _ -> reject(conn)
    end
  end

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      401,
      Jason.encode!(%{error: "unauthorized", message: "missing or invalid bearer token"})
    )
    |> halt()
  end
end
