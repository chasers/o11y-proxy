defmodule O11yProxy.Caller do
  @moduledoc """
  Identity of whoever is making a request. Threaded through the query layer from day
  one so a shared deployment (per-caller creds, rate limits, cache scoping, audit log)
  is additive later rather than a retrofit.
  """

  @enforce_keys [:id, :scopes]
  defstruct [:id, :scopes]

  @type t :: %__MODULE__{id: String.t(), scopes: [atom()]}

  @doc "The only caller in a local single-user deployment."
  @spec local() :: t()
  def local, do: %__MODULE__{id: "local", scopes: [:*]}
end
