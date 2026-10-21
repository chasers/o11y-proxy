defmodule O11yProxy.Auth.OIDC.Verifier do
  @moduledoc """
  Verifies a compact JWS bearer token against an issuer's published keys and checks the
  registered claims. Pure: keys come in as an argument and `now` is injectable, so every
  rejection path is testable with a locally generated key and no issuer at all.

  The rules are the standard ones for a resource server, chosen to fail closed:

    * the accepted algorithms are an explicit allow-list of *asymmetric* algorithms, and
      `JOSE.JWT.verify_strict/3` refuses anything else — so `alg: none`, and an HMAC token
      "signed" with the issuer's public key as the secret, never verify;
    * symmetric (`oct`) keys in a JWKS are dropped when it is parsed, for the same reason;
    * `iss` must equal the configured issuer exactly, `aud` must contain a configured
      audience, and `exp` is required. `nbf` is honoured when present.
  """

  alias O11yProxy.Auth.Claims

  @asymmetric ~w(RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512 EdDSA)

  @doc "Every algorithm `algorithms:` may name."
  @spec supported_algorithms() :: [String.t()]
  def supported_algorithms, do: @asymmetric

  @doc """
  Decodes the token's protected header without verifying anything, to learn its `kid`.
  Done by hand rather than with `JOSE.JWS.peek_protected/1`, which raises on malformed
  input — and a bearer token is input from anyone.
  """
  @spec header(String.t()) :: {:ok, map()} | {:error, String.t()}
  def header(token) when is_binary(token) do
    with [encoded, _payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{} = header} <- Jason.decode(json) do
      {:ok, header}
    else
      _ -> {:error, "bearer token is not a well-formed JWT"}
    end
  end

  @doc """
  Picks the verifying key for a token header. A `kid` must match exactly; a token with no
  `kid` is accepted only when the key set holds exactly one key, since guessing between
  several would make key rotation ambiguous.
  """
  @spec select_key(%{optional(String.t()) => JOSE.JWK.t()}, map()) ::
          {:ok, JOSE.JWK.t()} | :error
  def select_key(keys, %{"kid" => kid}) when is_binary(kid), do: Map.fetch(keys, kid)

  def select_key(keys, _header) do
    case Map.values(keys) do
      [only] -> {:ok, only}
      _ -> :error
    end
  end

  @doc """
  Parses a JWKS document into `%{kid => JOSE.JWK}`. Entries that are not signing keys,
  are symmetric, or are malformed are skipped rather than failing the whole set: one bad
  entry published during a rotation should not take every other key down with it. A key
  without a `kid` is kept under `""` so a single-key set still works.
  """
  @spec parse_jwks(term()) :: {:ok, %{optional(String.t()) => JOSE.JWK.t()}} | :error
  def parse_jwks(%{"keys" => keys}) when is_list(keys) do
    {:ok,
     keys
     |> Enum.filter(&usable_key?/1)
     |> Map.new(fn key -> {Map.get(key, "kid", ""), JOSE.JWK.from_map(key)} end)}
  end

  def parse_jwks(_other), do: :error

  # JOSE.JWK.from_map/1 raises a different exception for each way a key map can be wrong,
  # so the shape is checked here first and from_map only ever sees a well-formed key.
  defp usable_key?(%{"kty" => kty} = key) do
    Map.get(key, "use", "sig") == "sig" and well_formed?(kty, key)
  end

  defp usable_key?(_key), do: false

  defp well_formed?("RSA", key), do: b64_members?(key, ["n", "e"])

  defp well_formed?("EC", %{"crv" => crv} = key) when crv in ["P-256", "P-384", "P-521"],
    do: b64_members?(key, ["x", "y"])

  defp well_formed?("OKP", %{"crv" => crv} = key) when crv in ["Ed25519", "Ed448"],
    do: b64_members?(key, ["x"])

  defp well_formed?(_kty, _key), do: false

  defp b64_members?(key, members) do
    Enum.all?(members, fn member ->
      with value when is_binary(value) <- Map.get(key, member),
           {:ok, decoded} when decoded != "" <- Base.url_decode64(value, padding: false) do
        true
      else
        _ -> false
      end
    end)
  end

  @doc """
  Verifies `token` with `jwk` and checks its registered claims.

  `opts`: `:issuer` (string), `:audiences` (list), `:algorithms` (list), `:leeway`
  (seconds) and `:now` (unix seconds). Returns the claims map, or a message suitable for
  the `401` body.
  """
  # `JOSE.JWT.verify_strict/3`'s spec lists only `{true | false, jwt, jws}`, but it returns
  # `{:error, _}` for a token whose payload is not JSON (checked against jose 1.11.12), and
  # a bearer token is attacker input. The clause stays; only this spec mismatch is muted.
  @dialyzer {:no_match, verify: 3}
  @spec verify(String.t(), JOSE.JWK.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def verify(token, jwk, opts) do
    case JOSE.JWT.verify_strict(jwk, Keyword.fetch!(opts, :algorithms), token) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> check_claims(claims, opts)
      {false, _jwt, _jws} -> {:error, "token signature does not verify"}
      {:error, _reason} -> {:error, "bearer token is not a well-formed JWT"}
    end
  end

  defp check_claims(claims, opts) do
    now = Keyword.fetch!(opts, :now)
    leeway = Keyword.get(opts, :leeway, 0)

    with :ok <- check_issuer(claims, Keyword.fetch!(opts, :issuer)),
         :ok <- check_audience(claims, Keyword.fetch!(opts, :audiences)),
         :ok <- check_expiry(claims, now, leeway),
         :ok <- check_not_before(claims, now, leeway) do
      {:ok, claims}
    end
  end

  defp check_issuer(%{"iss" => issuer}, issuer), do: :ok
  defp check_issuer(_claims, _issuer), do: {:error, "token issuer is not trusted"}

  defp check_audience(%{"aud" => aud}, audiences) do
    case Claims.strings(aud) do
      {:ok, values} ->
        if Enum.any?(values, &(&1 in audiences)),
          do: :ok,
          else: {:error, "token audience does not include this service"}

      :error ->
        {:error, "token audience does not include this service"}
    end
  end

  defp check_audience(_claims, _audiences), do: {:error, "token has no audience"}

  defp check_expiry(%{"exp" => exp}, now, leeway) when is_number(exp) do
    if now < exp + leeway, do: :ok, else: {:error, "token has expired"}
  end

  defp check_expiry(_claims, _now, _leeway), do: {:error, "token has no expiry"}

  defp check_not_before(%{"nbf" => nbf}, now, leeway) when is_number(nbf) do
    if now + leeway >= nbf, do: :ok, else: {:error, "token is not valid yet"}
  end

  defp check_not_before(_claims, _now, _leeway), do: :ok
end
