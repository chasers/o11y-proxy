defmodule O11yProxy.Test.OIDC do
  @moduledoc """
  A local stand-in for an OpenID Connect issuer: generates signing keys, signs tokens,
  and serves discovery and JWKS documents through a `Req` function plug, so the OIDC path
  is tested end to end without any real identity provider.

  The served key set lives in an `Agent`, so a test can rotate keys mid-run, and the
  agent counts JWKS fetches so refetch rate limiting is observable.
  """

  import Plug.Conn

  @issuer "https://issuer.test"
  @audience "o11y-proxy"

  def issuer, do: @issuer
  def audience, do: @audience

  @doc "An RSA signing key carrying `kid`."
  def key(kid \\ "key-1") do
    {:rsa, 2048} |> JOSE.JWK.generate_key() |> JOSE.JWK.merge(%{"kid" => kid})
  end

  @doc "The public JWKS document for `keys`."
  def jwks(keys) do
    %{
      "keys" =>
        Enum.map(keys, fn key ->
          {_, map} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
          map
        end)
    }
  end

  @doc "Registered claims for a valid token, with `overrides` merged on top."
  def claims(overrides \\ %{}) do
    Map.merge(
      %{
        "iss" => @issuer,
        "aud" => @audience,
        "sub" => "user-1",
        "exp" => System.system_time(:second) + 300
      },
      overrides
    )
  end

  @doc "A compact JWS signed by `key`; `header` is merged over `alg`/`kid`."
  def token(key, claims, header \\ %{}) do
    {_, %{"kid" => kid}} = JOSE.JWK.to_map(key)
    header = Map.merge(%{"alg" => "RS256", "kid" => kid}, header)
    {_, token} = key |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
    token
  end

  @doc """
  Starts an agent holding the served key set and a JWKS fetch counter. `discovery` is
  merged into the discovery document, to test a mismatched issuer and the like.
  """
  def start_issuer(keys, discovery \\ %{}) do
    {:ok, agent} =
      Agent.start_link(fn -> %{keys: keys, fetches: 0, discovery: discovery, down: false} end)

    agent
  end

  def rotate(agent, keys), do: Agent.update(agent, &%{&1 | keys: keys})
  def take_down(agent), do: Agent.update(agent, &%{&1 | down: true})
  def fetches(agent), do: Agent.get(agent, & &1.fetches)

  @doc "`req_options` that route `Keys`' HTTP calls to the issuer in `agent`."
  def req_options(agent), do: [plug: &serve(agent, &1)]

  defp serve(agent, conn) do
    state = Agent.get(agent, & &1)

    case {state.down, conn.request_path} do
      {true, _path} ->
        send_resp(conn, 503, "down")

      {false, "/.well-known/openid-configuration"} ->
        Req.Test.json(
          conn,
          Map.merge(
            %{
              "issuer" => @issuer,
              "jwks_uri" => @issuer <> "/jwks",
              "id_token_signing_alg_values_supported" => ["RS256"]
            },
            state.discovery
          )
        )

      {false, "/jwks"} ->
        Agent.update(agent, &%{&1 | fetches: &1.fetches + 1})
        Req.Test.json(conn, jwks(state.keys))

      {false, _other} ->
        send_resp(conn, 404, "not found")
    end
  end

  @doc "The validated `server.oidc` map `Keys` and `Auth.OIDC` expect, with overrides."
  def config(overrides \\ %{}) do
    Map.merge(
      %{
        issuer: @issuer,
        audience: [@audience],
        jwks_refresh_seconds: 300,
        leeway_seconds: 0,
        identity_claim: "sub",
        role_claim: "o11y.role"
      },
      overrides
    )
  end

  @doc """
  Starts `O11yProxy.Auth.OIDC.Keys` against `agent` under the test supervisor and waits
  for its first fetch to land, so a test never races the initial load.
  """
  def start_keys(agent, overrides \\ %{}) do
    opts = Map.merge(config(overrides), %{req_options: req_options(agent)})
    pid = ExUnit.Callbacks.start_supervised!({O11yProxy.Auth.OIDC.Keys, opts})
    # A call is processed only after handle_continue has run the first fetch.
    _ = :sys.get_state(pid)
    pid
  end
end
