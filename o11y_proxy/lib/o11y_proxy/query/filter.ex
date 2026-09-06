defmodule O11yProxy.Query.Filter do
  @moduledoc "One canonical filter clause. See `.plans/01-agent-contract.md`."

  @operators [:eq, :neq, :gte, :lte, :contains, :regex, :in, :exists]

  @enforce_keys [:field, :op, :value]
  defstruct [:field, :op, :value]

  @type t :: %__MODULE__{field: String.t(), op: atom(), value: term()}

  @spec operators() :: [atom()]
  def operators, do: @operators

  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(%{"field" => field, "op" => op, "value" => value})
      when is_binary(field) and is_binary(op) do
    case Enum.find(@operators, &(Atom.to_string(&1) == op)) do
      nil -> {:error, {:unsupported_operator, op}}
      atom_op -> {:ok, %__MODULE__{field: field, op: atom_op, value: value}}
    end
  end

  def parse(other), do: {:error, {:invalid_filter, other}}
end
