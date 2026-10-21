defmodule O11yProxy.Auth do
  @moduledoc """
  Authenticates a request into an `O11yProxy.Caller`.

  A behaviour with one callback, so the mechanism is swappable without touching a
  transport: the HTTP plug hands over the request headers and gets a caller or a failure
  back, and a future transport would do the same. Three implementations ship, selected by
  `server.auth`:

    * `none` — `O11yProxy.Auth.None`, the local single-user default;
    * `token` — `O11yProxy.Auth.Token`, one shared static bearer token;
    * `oidc` — `O11yProxy.Auth.OIDC`, a JWT from any OpenID Connect issuer, mapped onto
      a configured `O11yProxy.Policy` by its role claim.

  An application embedding o11y-proxy can replace the module behind a mode without
  forking, by mapping the mode to its own implementation of this behaviour:

      config :o11y_proxy, :authenticators, %{oidc: MyApp.O11yAuth}

  The mode itself always comes from the fixed set above. It is looked up, never built
  from config text, so no configured string becomes an atom.
  """

  alias O11yProxy.Caller

  @typedoc """
  Why a request was refused: `:unauthorized` (no or bad credentials, 401), `:forbidden`
  (a valid identity this service grants nothing to, 403), `:unavailable` (the server
  cannot verify anyone right now, 503).
  """
  @type failure :: {:unauthorized | :forbidden | :unavailable, String.t()}

  @type mode :: :none | :token | :oidc

  @callback authenticate(headers :: [{String.t(), String.t()}]) ::
              {:ok, Caller.t()} | {:error, failure()}

  @builtin %{none: __MODULE__.None, token: __MODULE__.Token, oidc: __MODULE__.OIDC}

  @doc "The implementation for `mode`, honouring any `:authenticators` override."
  @spec impl(mode()) :: module()
  def impl(mode) do
    overrides = Application.get_env(:o11y_proxy, :authenticators, %{})
    Map.get(overrides, mode) || Map.fetch!(@builtin, mode)
  end

  @doc "Authenticates `headers` with the configured mode's implementation."
  @spec authenticate(mode(), [{String.t(), String.t()}]) ::
          {:ok, Caller.t()} | {:error, failure()}
  def authenticate(mode, headers), do: impl(mode).authenticate(headers)

  @doc """
  The bearer token from an `authorization` header. Header names arrive lowercased from
  Plug; the scheme is matched case-insensitively, as RFC 6750 allows. More than one
  `authorization` header is refused rather than guessed between.
  """
  @spec bearer([{String.t(), String.t()}]) :: {:ok, String.t()} | {:error, failure()}
  def bearer(headers) do
    case for({"authorization", value} <- headers, do: value) do
      [value] -> parse_bearer(value)
      _none_or_many -> missing()
    end
  end

  defp parse_bearer(value) do
    with [scheme, token] <- String.split(value, " ", parts: 2),
         "bearer" <- String.downcase(scheme),
         token when token != "" <- String.trim(token) do
      {:ok, token}
    else
      _ -> missing()
    end
  end

  defp missing,
    do: {:error, {:unauthorized, "send credentials as an Authorization: Bearer <token> header"}}
end

defmodule O11yProxy.Auth.None do
  @moduledoc """
  `server.auth: none`. Every request is the local caller, with no policy. Config refuses
  this mode on anything but a loopback bind.
  """
  @behaviour O11yProxy.Auth

  @impl true
  def authenticate(_headers), do: {:ok, O11yProxy.Caller.local()}
end

defmodule O11yProxy.Auth.Token do
  @moduledoc """
  `server.auth: token`. One static bearer token, from `O11Y_PROXY_TOKEN`, shared by every
  caller, who then has no policy. An unset variable rejects every request rather than
  accepting an empty token.
  """
  @behaviour O11yProxy.Auth

  @impl true
  def authenticate(headers) do
    expected = System.get_env("O11Y_PROXY_TOKEN")

    with {:ok, token} <- O11yProxy.Auth.bearer(headers),
         true <- is_binary(expected) and Plug.Crypto.secure_compare(token, expected) do
      {:ok, O11yProxy.Caller.local()}
    else
      _ -> {:error, {:unauthorized, "missing or invalid bearer token"}}
    end
  end
end
