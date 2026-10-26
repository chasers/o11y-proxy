defmodule O11yProxy.Caller do
  @moduledoc """
  Identity of whoever is making a request, and the policy that bounds what they may do.
  Threaded from the transport to `O11yProxy.Sources.run_query/4`, which is where the
  policy is enforced — once, for every transport.

  `policy: nil` means unrestricted. That is the local caller: the `none` and `token`
  auth modes, and the CLI, whose access is already gated by being on the machine (and,
  for a daemon, by the Erlang cookie).
  """

  @enforce_keys [:id]
  defstruct id: nil, policy: nil, claims: %{}

  @type t :: %__MODULE__{
          id: String.t(),
          policy: O11yProxy.Policy.t() | nil,
          claims: map()
        }

  @doc "The unrestricted caller of a local or shared-token deployment."
  @spec local() :: t()
  def local, do: %__MODULE__{id: "local"}
end
