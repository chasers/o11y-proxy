defmodule O11yProxy.Config.Policies do
  @moduledoc """
  Builds the `policies:` block into `O11yProxy.Policy` structs, refusing at load every
  definition that would boot but not restrict what its author meant it to.

  Policy and source names stay strings throughout; nothing a config file names becomes an
  atom. The few enumerated values (`raw`, `modes`) are looked up against fixed lists.
  """

  alias O11yProxy.Config
  alias O11yProxy.Policy
  alias O11yProxy.Policy.Constraint
  alias O11yProxy.Query

  @sources_type {:or, [{:in, ["*"]}, {:list, :string}]}

  @policy_schema [
    sources: [type: @sources_type, required: true, doc: "source names, or \"*\""],
    raw: [type: {:in, ["allow", "deny"]}, default: "deny"],
    modes: [type: {:list, {:in, ["summary", "sample", "full"]}}],
    max_limit: [type: :pos_integer],
    max_lookback: [type: :string, doc: "e.g. 7d; a query's from may reach no further back"],
    constraints: [type: {:list, :any}, default: []]
  ]

  @constraint_schema [
    field: [type: :string, required: true, doc: "canonical filter field, e.g. labels.project"],
    sources: [type: @sources_type, default: "*"],
    require: [type: :boolean, default: false],
    inject: [type: :boolean, default: false],
    allowed: [type: {:or, [{:in, ["*"]}, {:list, {:or, [:string, :integer, :boolean]}}]}],
    allowed_claim: [type: :string, doc: "claim path holding the caller's allowed values"]
  ]

  @doc """
  `raw` is the YAML `policies:` mapping; `source_names` the configured sources, which every
  name a policy mentions must be one of — a typo in an allow-list otherwise silently
  denies, and a typo in a constraint silently fails to constrain.
  """
  @spec build(term(), [String.t()]) ::
          {:ok, %{optional(String.t()) => Policy.t()}} | {:error, term()}
  def build(raw, source_names) when is_map(raw) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {name, body}, {:ok, acc} ->
      case build_policy(name, body, source_names) do
        {:ok, policy} -> {:cont, {:ok, Map.put(acc, policy.name, policy)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def build(other, _source_names), do: {:error, {:invalid_block_shape, :policies, other}}

  defp build_policy(name, body, source_names) when is_binary(name) do
    block = "policies.#{name}"

    with {:ok, opts} <- Config.validate_block(body, @policy_schema, block),
         opts = Map.new(opts),
         {:ok, sources} <- known_sources(opts.sources, source_names, block),
         {:ok, lookback} <- lookback(Map.get(opts, :max_lookback), block),
         {:ok, constraints} <- build_constraints(opts.constraints, source_names, block),
         :ok <- check_raw(opts.raw, constraints, block) do
      {:ok,
       %Policy{
         name: name,
         sources: sources,
         raw: raw_atom(opts.raw),
         modes: modes(Map.get(opts, :modes)),
         max_limit: Map.get(opts, :max_limit),
         max_lookback: Map.get(opts, :max_lookback),
         max_lookback_seconds: lookback,
         constraints: constraints
       }}
    end
  end

  defp build_policy(name, _body, _source_names),
    do: {:error, {:invalid_block, :policies, "policy name #{inspect(name)} must be a string"}}

  defp known_sources("*", _known, _block), do: {:ok, :all}

  defp known_sources(names, known, block) do
    case Enum.reject(names, &(&1 in known)) do
      [] ->
        {:ok, names}

      unknown ->
        noun = if match?([_], unknown), do: "source", else: "sources"
        named = Enum.map_join(unknown, ", ", &inspect/1)
        configured = if known == [], do: "none", else: Enum.join(known, ", ")

        {:error,
         {:invalid_block, block, "unknown #{noun} #{named}; configured sources: #{configured}"}}
    end
  end

  defp lookback(nil, _block), do: {:ok, nil}

  defp lookback(value, block) do
    case Query.Time.duration_seconds(value) do
      {:ok, seconds} ->
        {:ok, seconds}

      {:error, _} ->
        {:error,
         {:invalid_block, block,
          "max_lookback #{inspect(value)} is not a duration like 15m, 24h or 7d"}}
    end
  end

  defp build_constraints(raw, source_names, block) do
    raw
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {body, index}, {:ok, acc} ->
      case build_constraint(body, source_names, "#{block}.constraints[#{index}]") do
        {:ok, constraint} -> {:cont, {:ok, [constraint | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp build_constraint(body, source_names, block) do
    with {:ok, opts} <- Config.validate_block(body, @constraint_schema, block),
         opts = Map.new(opts),
         {:ok, sources} <- known_sources(opts.sources, source_names, block),
         {:ok, allowed, claim} <- allowed(opts, block),
         :ok <- check_inject(opts.inject, allowed, claim, block) do
      {:ok,
       %Constraint{
         field: opts.field,
         sources: sources,
         require: opts.require,
         inject: opts.inject,
         allowed: allowed,
         allowed_claim: claim
       }}
    end
  end

  defp allowed(%{allowed: _, allowed_claim: _}, block),
    do: constraint_error(block, "set allowed or allowed_claim, not both")

  defp allowed(%{allowed: "*"}, _block), do: {:ok, :any, nil}
  defp allowed(%{allowed: values}, _block), do: {:ok, values, nil}

  # Bound per request from the caller's token; until then, nothing is allowed.
  defp allowed(%{allowed_claim: claim}, _block), do: {:ok, [], claim}

  defp allowed(_opts, block),
    do:
      constraint_error(
        block,
        "set allowed (a list, or \"*\" for any value) or allowed_claim (a claim path)"
      )

  # Injection adds `field in allowed`, which has no meaning for "any value".
  defp check_inject(true, :any, nil, block),
    do: constraint_error(block, "inject needs a bounded allowed list or an allowed_claim")

  defp check_inject(_inject, _allowed, _claim, _block), do: :ok

  # `raw` is a query the policy cannot see inside, so any constraint would be decorative.
  defp check_raw("allow", [_ | _], block) do
    {:error,
     {:invalid_block, block,
      "raw: allow would bypass this policy's constraints; use raw: deny, or move the " <>
        "constraints to a separate policy"}}
  end

  defp check_raw(_raw, _constraints, _block), do: :ok

  defp constraint_error(block, message), do: {:error, {:invalid_block, block, message}}

  defp raw_atom("allow"), do: :allow
  defp raw_atom("deny"), do: :deny

  defp modes(nil), do: :all

  defp modes(names) do
    Enum.map(names, fn name -> Enum.find(Query.modes(), &(Atom.to_string(&1) == name)) end)
  end
end
