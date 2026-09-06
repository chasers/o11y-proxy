defmodule O11yProxy.CredentialResolver do
  @moduledoc """
  Seam between a source's config and the credentials an adapter actually uses.

  v1 is single-user/local: config already holds `${ENV_VAR}` values interpolated at load
  time (see `O11yProxy.Config`), so the default resolver is the identity function. A
  shared deployment swaps in a resolver that looks up per-caller credentials instead —
  adapters call `resolve/2` and never know the difference. See `.plans/04-cross-cutting.md`.
  """

  @callback resolve(source_opts :: map(), caller :: O11yProxy.Caller.t()) ::
              {:ok, map()} | {:error, term()}

  @doc "Configured resolver module, defaulting to #{inspect(__MODULE__.Env)}."
  @spec impl() :: module()
  def impl, do: Application.get_env(:o11y_proxy, :credential_resolver, __MODULE__.Env)

  @spec resolve(map(), O11yProxy.Caller.t()) :: {:ok, map()} | {:error, term()}
  def resolve(source_opts, caller), do: impl().resolve(source_opts, caller)
end

defmodule O11yProxy.CredentialResolver.Env do
  @moduledoc "Default resolver: source config was already env-interpolated at load time."
  @behaviour O11yProxy.CredentialResolver

  @impl true
  def resolve(source_opts, _caller), do: {:ok, source_opts}
end
