defmodule O11yProxy.Policy do
  @moduledoc """
  Role-based access to sources, and to the queries that may be run against them.

  A policy is defined once in config (`policies:`), selected per request from a verified
  token's role claim, and then *bound* to that token's claims so a constraint such as
  "only these projects" carries the caller's own values. `authorize/4` is applied to the
  canonical `O11yProxy.Query` before any adapter compiles it, which is what makes one rule
  hold identically for every backend: an injected filter reaches ClickHouse as a bound
  parameter and VictoriaMetrics as an escaped matcher, exactly like a filter the caller
  wrote, and shows up in `meta.native_queries` so nothing is rewritten out of sight.

  Pure: no process, no config lookup. `nil` stands for "no policy" — the local CLI caller
  and the `none`/`token` auth modes — and every function here treats it as unrestricted.

  Violations are `{:error, {:forbidden, message}}`, and the message is written for an
  agent to act on: it names the field, the operators that are allowed and the values the
  caller may use, rather than only saying no.
  """

  alias O11yProxy.Auth.Claims
  alias O11yProxy.Query
  alias O11yProxy.Query.Filter

  defmodule Constraint do
    @moduledoc """
    One rule over one canonical filter field, for some or all of a policy's sources.

      * `require` — the query must carry an `eq` or `in` filter on `field`.
      * `inject` — when the query has no filter on `field`, add `field in allowed`.
      * `allowed` — the values an `eq`/`in` filter on `field` may use, or `:any`.
      * `allowed_claim` — read `allowed` from this claim path at bind time instead.
    """

    @enforce_keys [:field]
    defstruct sources: :all,
              field: nil,
              require: false,
              inject: false,
              allowed: :any,
              allowed_claim: nil

    @type t :: %__MODULE__{
            sources: :all | [String.t()],
            field: String.t(),
            require: boolean(),
            inject: boolean(),
            allowed: :any | [String.t() | integer() | boolean()],
            allowed_claim: String.t() | nil
          }
  end

  @enforce_keys [:name]
  defstruct name: nil,
            sources: :all,
            raw: :deny,
            modes: :all,
            max_limit: nil,
            max_lookback: nil,
            max_lookback_seconds: nil,
            constraints: []

  @type t :: %__MODULE__{
          name: String.t(),
          sources: :all | [String.t()],
          raw: :allow | :deny,
          modes: :all | [atom()],
          max_limit: pos_integer() | nil,
          max_lookback: String.t() | nil,
          max_lookback_seconds: pos_integer() | nil,
          constraints: [Constraint.t()]
        }

  @type violation :: {:forbidden, String.t()}

  # Only operators whose values can be checked against an allow-list. `neq`, `regex`,
  # `contains` and `exists` on a constrained field would each let a caller reach values
  # outside it, so they are refused rather than interpreted.
  @scoped_ops [:eq, :in]

  # A relative `from` such as `now-7d` is resolved when the request is parsed, a moment
  # before it is checked here against a fresh `now`. Without slack, asking for exactly the
  # cap would be refused by however many microseconds passed in between.
  @lookback_slack_seconds 60

  @doc """
  Resolves every `allowed_claim` against the caller's verified claims.

  An absent claim binds to the empty list, so constrained sources permit nothing while
  the rest of the policy still works; the message a caller then gets names the missing
  claim. A claim that is present but not a scalar or list of scalars is refused outright,
  since it signals an issuer misconfiguration rather than a caller with no grants.
  """
  @spec bind(t(), map()) :: {:ok, t()} | {:error, violation()}
  def bind(%__MODULE__{constraints: constraints} = policy, claims) do
    constraints
    |> Enum.reduce_while({:ok, []}, fn constraint, {:ok, acc} ->
      case bind_constraint(constraint, claims) do
        {:ok, bound} -> {:cont, {:ok, [bound | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, bound} -> {:ok, %{policy | constraints: Enum.reverse(bound)}}
      error -> error
    end
  end

  defp bind_constraint(%Constraint{allowed_claim: nil} = constraint, _claims),
    do: {:ok, constraint}

  defp bind_constraint(%Constraint{allowed_claim: path} = constraint, claims) do
    case Claims.get(claims, path) do
      :error ->
        {:ok, %{constraint | allowed: []}}

      {:ok, value} ->
        case Claims.scalars(value) do
          {:ok, values} ->
            {:ok, %{constraint | allowed: values}}

          :error ->
            {:error,
             {:forbidden,
              "token claim #{path} must be a string, number or a list of them, so " <>
                "the #{constraint.field} constraint cannot be applied"}}
        end
    end
  end

  @doc "Whether this policy lets its caller see and query `source` at all."
  @spec permits_source?(t() | nil, String.t()) :: boolean()
  def permits_source?(nil, _source), do: true
  def permits_source?(%__MODULE__{sources: :all}, _source), do: true
  def permits_source?(%__MODULE__{sources: sources}, source), do: source in sources

  @doc """
  The checks a source has to pass before anything is fetched from it, for a request that
  carries no query (schema discovery). Only the source allow-list applies.
  """
  @spec authorize_source(t() | nil, String.t()) :: :ok | {:error, violation()}
  def authorize_source(policy, source) do
    if permits_source?(policy, source) do
      :ok
    else
      {:error,
       {:forbidden,
        "policy #{inspect(policy.name)} does not permit source #{inspect(source)}; " <>
          "permitted sources: #{describe_sources(policy.sources)}"}}
    end
  end

  @doc """
  For a lookup by ID (an error fetched by its own ID), which carries no filters a
  constraint could be checked against. Allowed only on a permitted source that no
  constraint applies to: an ID is not scoped, so answering it would bypass the scope.
  """
  @spec authorize_lookup(t() | nil, String.t()) :: :ok | {:error, violation()}
  def authorize_lookup(nil, _source), do: :ok

  def authorize_lookup(policy, source) do
    with :ok <- authorize_source(policy, source) do
      case Enum.find(policy.constraints, &applies?(&1, source)) do
        nil ->
          :ok

        constraint ->
          {:error,
           {:forbidden,
            "a lookup by ID cannot be scoped by #{constraint.field}, so policy " <>
              "#{inspect(policy.name)} does not allow it on source #{inspect(source)}; " <>
              "use a query with a #{constraint.field} filter instead"}}
      end
    end
  end

  @doc """
  Checks `query` against the policy for one source and returns it with any injected
  filters added. `now` anchors the lookback cap and is injectable for tests.
  """
  @spec authorize(t() | nil, String.t(), Query.t(), DateTime.t()) ::
          {:ok, Query.t()} | {:error, violation()}
  def authorize(nil, _source, query, _now), do: {:ok, query}

  def authorize(%__MODULE__{} = policy, source, %Query{} = query, now) do
    with :ok <- authorize_source(policy, source),
         :ok <- check_raw(policy, query),
         :ok <- check_mode(policy, query),
         :ok <- check_limit(policy, query),
         :ok <- check_lookback(policy, query, now) do
      apply_constraints(policy, source, query)
    end
  end

  @doc """
  The furthest back, in seconds, this policy lets a query reach, or `nil` for no cap.
  `/v1/context` uses it to keep the window *it* picks inside what the caller may see.
  """
  @spec lookback_cap(t() | nil) :: pos_integer() | nil
  def lookback_cap(nil), do: nil
  def lookback_cap(%__MODULE__{max_lookback_seconds: seconds}), do: seconds

  @doc "The largest `limit` this policy accepts, or `nil` for no cap."
  @spec limit_cap(t() | nil) :: pos_integer() | nil
  def limit_cap(nil), do: nil
  def limit_cap(%__MODULE__{max_limit: limit}), do: limit

  # -- query-level checks ---------------------------------------------------------------

  # The raw escape hatch bypasses the canonical filters, and with them every constraint,
  # which is also why config refuses `raw: allow` on a policy that has any.
  defp check_raw(%{raw: :deny} = policy, %Query{raw: raw}) when is_binary(raw) do
    {:error,
     {:forbidden,
      "policy #{inspect(policy.name)} does not allow raw queries; express the query " <>
        "with filters instead"}}
  end

  defp check_raw(_policy, _query), do: :ok

  defp check_mode(%{modes: :all}, _query), do: :ok

  defp check_mode(%{modes: modes} = policy, %Query{mode: mode}) do
    if mode in modes do
      :ok
    else
      {:error,
       {:forbidden,
        "mode #{mode} is not allowed by policy #{inspect(policy.name)}; allowed modes: " <>
          Enum.map_join(modes, ", ", &Atom.to_string/1)}}
    end
  end

  defp check_limit(%{max_limit: nil}, _query), do: :ok

  defp check_limit(%{max_limit: max} = policy, %Query{limit: limit}) when limit > max do
    {:error,
     {:forbidden,
      "limit #{limit} exceeds policy #{inspect(policy.name)}'s max_limit of #{max}; " <>
        "ask for #{max} or fewer and page with the cursor"}}
  end

  defp check_limit(_policy, _query), do: :ok

  defp check_lookback(%{max_lookback_seconds: nil}, _query, _now), do: :ok

  defp check_lookback(%{max_lookback_seconds: seconds} = policy, %Query{from: from}, now) do
    earliest = DateTime.add(now, -seconds, :second)

    if DateTime.compare(from, DateTime.add(earliest, -@lookback_slack_seconds, :second)) == :lt do
      {:error,
       {:forbidden,
        "from reaches further back than policy #{inspect(policy.name)}'s max_lookback " <>
          "of #{policy.max_lookback}; use a from no earlier than " <>
          DateTime.to_iso8601(earliest)}}
    else
      :ok
    end
  end

  # -- constraints ----------------------------------------------------------------------

  # In order, so an injected filter is already present when a later constraint on the
  # same field checks the query.
  defp apply_constraints(policy, source, query) do
    policy.constraints
    |> Enum.filter(&applies?(&1, source))
    |> Enum.reduce_while({:ok, query}, fn constraint, {:ok, acc} ->
      case apply_constraint(constraint, source, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp applies?(%Constraint{sources: :all}, _source), do: true
  defp applies?(%Constraint{sources: sources}, source), do: source in sources

  defp apply_constraint(constraint, source, query) do
    case Enum.filter(query.filters, &(&1.field == constraint.field)) do
      [] -> when_absent(constraint, source, query)
      filters -> check_filters(constraint, filters, query)
    end
  end

  defp when_absent(%Constraint{inject: true, allowed: []} = constraint, source, _query) do
    {:error,
     {:forbidden,
      "your token grants no #{constraint.field} values#{claim_hint(constraint)}, so " <>
        "source #{inspect(source)} cannot be queried"}}
  end

  defp when_absent(%Constraint{inject: true, allowed: allowed} = constraint, _source, query)
       when is_list(allowed) do
    filter =
      case allowed do
        [single] -> %Filter{field: constraint.field, op: :eq, value: single}
        many -> %Filter{field: constraint.field, op: :in, value: many}
      end

    {:ok, %{query | filters: query.filters ++ [filter]}}
  end

  defp when_absent(%Constraint{require: true} = constraint, source, _query) do
    {:error,
     {:forbidden,
      "source #{inspect(source)} requires a filter on #{constraint.field} with op eq or " <>
        "in; #{describe_allowed(constraint)}"}}
  end

  defp when_absent(_constraint, _source, query), do: {:ok, query}

  defp check_filters(constraint, filters, query) do
    filters
    |> Enum.reduce_while(:ok, fn filter, :ok ->
      case check_filter(constraint, filter) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> {:ok, query}
      error -> error
    end
  end

  defp check_filter(constraint, %Filter{op: op}) when op not in @scoped_ops do
    {:error,
     {:forbidden,
      "a filter on #{constraint.field} must use op eq or in, not #{op}; " <>
        describe_allowed(constraint)}}
  end

  defp check_filter(constraint, %Filter{op: :in, value: values}) when not is_list(values) do
    {:error, {:forbidden, "a filter on #{constraint.field} with op in needs a list of values"}}
  end

  defp check_filter(%Constraint{allowed: :any}, _filter), do: :ok

  defp check_filter(constraint, %Filter{value: value}) do
    permitted = MapSet.new(constraint.allowed, &to_string/1)

    case Enum.reject(List.wrap(value), &MapSet.member?(permitted, to_string(&1))) do
      [] ->
        :ok

      denied ->
        {:error,
         {:forbidden,
          "#{constraint.field} #{noun(denied)} " <>
            "#{Enum.map_join(denied, ", ", &inspect/1)} #{verb(denied)} not permitted; " <>
            describe_allowed(constraint)}}
    end
  end

  defp describe_allowed(%Constraint{allowed: :any}), do: "any value is allowed"

  defp describe_allowed(%Constraint{allowed: []} = constraint),
    do: "your token grants no values#{claim_hint(constraint)}"

  defp describe_allowed(%Constraint{allowed: allowed}),
    do: "allowed values: #{Enum.map_join(allowed, ", ", &inspect/1)}"

  defp claim_hint(%Constraint{allowed_claim: nil}), do: ""
  defp claim_hint(%Constraint{allowed_claim: path}), do: " (from claim #{path})"

  defp noun([_]), do: "value"
  defp noun(_many), do: "values"

  defp verb([_]), do: "is"
  defp verb(_many), do: "are"

  defp describe_sources(:all), do: "all"
  defp describe_sources(sources), do: Enum.join(sources, ", ")
end
