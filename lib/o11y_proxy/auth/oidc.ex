defmodule O11yProxy.Auth.OIDC do
  @moduledoc """
  `server.auth: oidc`. Accepts a JWT bearer token from any OpenID Connect issuer and maps
  it onto a configured `O11yProxy.Policy`.

  Nothing here is specific to an issuer. What the issuer has to provide is the standard
  minimum: a JWKS (via discovery or a configured `jwks_uri`), asymmetric signatures, an
  `aud` naming this service, `exp`, and a claim naming the caller's role. Which claims
  hold the identity, the role and any constraint values is configuration — the claim
  paths are looked up with `O11yProxy.Auth.Claims`.

  The steps, each failing closed:

    1. take the bearer token from the `authorization` header;
    2. find its key by `kid` (`O11yProxy.Auth.OIDC.Keys`);
    3. verify the signature and registered claims (`O11yProxy.Auth.OIDC.Verifier`);
    4. pick exactly one policy from the role claim, or `default_policy`;
    5. bind the policy's constraints to this token's claims.

  Steps 1–3 failing is `401`; 4–5 is `403`, because the caller *is* who they say and this
  service simply grants them nothing.
  """

  @behaviour O11yProxy.Auth

  alias O11yProxy.Auth.Claims
  alias O11yProxy.Auth.OIDC.{Keys, Verifier}
  alias O11yProxy.{Caller, Policy}

  @impl true
  def authenticate(headers) do
    config = Application.fetch_env!(:o11y_proxy, :oidc)
    policies = Application.get_env(:o11y_proxy, :policies, %{})

    with {:ok, token} <- O11yProxy.Auth.bearer(headers),
         {:ok, claims} <- verify(token, config),
         {:ok, id} <- identity(claims, config),
         {:ok, policy} <- select_policy(claims, config, policies),
         {:ok, bound} <- Policy.bind(policy, claims) do
      {:ok, %Caller{id: id, policy: bound, claims: claims}}
    end
  end

  defp verify(token, config) do
    with {:ok, header} <- unauthorized(Verifier.header(token)),
         {:ok, jwk, algorithms} <- key(header) do
      token
      |> Verifier.verify(jwk,
        issuer: config.issuer,
        audiences: config.audience,
        algorithms: algorithms,
        leeway: config.leeway_seconds,
        now: System.system_time(:second)
      )
      |> unauthorized()
    end
  end

  defp key(header) do
    case Keys.lookup(header) do
      {:ok, jwk, algorithms} ->
        {:ok, jwk, algorithms}

      {:error, :unknown_key} ->
        {:error, {:unauthorized, "token is not signed by a key this issuer publishes"}}

      {:error, :unavailable} ->
        {:error,
         {:unavailable, "the issuer's signing keys could not be loaded; try again shortly"}}
    end
  end

  defp identity(claims, %{identity_claim: path}) do
    case Claims.get(claims, path) do
      {:ok, id} when is_binary(id) and id != "" -> {:ok, id}
      {:ok, id} when is_integer(id) -> {:ok, Integer.to_string(id)}
      _ -> {:error, {:unauthorized, "token has no usable #{path} claim to identify the caller"}}
    end
  end

  @doc false
  # Exactly one of the token's roles has to name a policy. Two would need a rule for
  # combining policies, and guessing one — union or intersection — is how access control
  # goes quietly wrong, so it is refused with a message that says how to fix it.
  @spec select_policy(map(), map(), %{optional(String.t()) => Policy.t()}) ::
          {:ok, Policy.t()} | {:error, O11yProxy.Auth.failure()}
  def select_policy(claims, config, policies) do
    with {:ok, roles} <- roles(claims, Map.get(config, :role_claim)) do
      case roles |> Enum.filter(&Map.has_key?(policies, &1)) |> Enum.uniq() do
        [role] ->
          {:ok, Map.fetch!(policies, role)}

        [] ->
          default_policy(config, policies, roles)

        several ->
          roles = Enum.join(several, ", ")

          {:error,
           {:forbidden,
            "token carries more than one role with a policy here (#{roles}); issue it with " <>
              "exactly one"}}
      end
    end
  end

  defp roles(_claims, nil), do: {:ok, []}

  defp roles(claims, path) do
    case Claims.get(claims, path) do
      :error ->
        {:ok, []}

      {:ok, value} ->
        case Claims.strings(value) do
          {:ok, roles} ->
            {:ok, roles}

          :error ->
            {:error, {:forbidden, "token claim #{path} must be a string or a list of strings"}}
        end
    end
  end

  defp default_policy(%{default_policy: name}, policies, _roles) when is_binary(name),
    do: {:ok, Map.fetch!(policies, name)}

  defp default_policy(config, _policies, roles) do
    held = if roles == [], do: "none", else: Enum.join(roles, ", ")

    {:error,
     {:forbidden,
      "no policy here matches the token's roles (claim #{Map.get(config, :role_claim)}: " <>
        "#{held})"}}
  end

  defp unauthorized({:ok, _} = ok), do: ok
  defp unauthorized({:error, message}), do: {:error, {:unauthorized, message}}
end
