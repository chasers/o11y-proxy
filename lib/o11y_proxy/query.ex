defmodule O11yProxy.Query do
  @moduledoc """
  The canonical query IR. Every backend's `compile/2` takes one of these. Built from the
  `POST /v1/query` request body per `.plans/01-agent-contract.md` — this module owns
  parsing and validating that shape; it does not know about any backend's dialect.
  """

  alias O11yProxy.Query.{Filter, Time}

  @signals [:logs, :metrics, :traces, :errors]
  @modes [:summary, :sample, :full]
  @orders [:asc, :desc]

  @enforce_keys [:signal, :from, :to]
  defstruct sources: nil,
            signal: nil,
            from: nil,
            to: nil,
            filters: [],
            raw: nil,
            mode: :summary,
            limit: 50,
            order: :desc,
            cursor: nil

  @type t :: %__MODULE__{
          sources: [String.t()] | nil,
          signal: :logs | :metrics | :traces | :errors,
          from: DateTime.t(),
          to: DateTime.t(),
          filters: [Filter.t()],
          raw: String.t() | nil,
          mode: :summary | :sample | :full,
          limit: pos_integer(),
          order: :asc | :desc,
          cursor: String.t() | nil
        }

  @spec signals() :: [atom()]
  def signals, do: @signals

  @spec modes() :: [atom()]
  def modes, do: @modes

  @doc """
  Parses a `POST /v1/query` request body (string-keyed map, e.g. straight from
  `Jason.decode!/1`) into a `t()`.

  `opts`:
    * `:default_limit` — used when the request omits `limit` (default `50`)
    * `:now` — anchor for relative time parsing, injectable for tests
  """
  @spec parse(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def parse(params, opts \\ []) when is_map(params) do
    default_limit = Keyword.get(opts, :default_limit, 50)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, signal} <- fetch_enum(params, "signal", @signals),
         {:ok, from} <- fetch_time(params, "from", now),
         {:ok, to} <- fetch_time(params, "to", now),
         {:ok, mode} <- fetch_enum(params, "mode", @modes, :summary),
         {:ok, order} <- fetch_enum(params, "order", @orders, :desc),
         {:ok, limit} <- fetch_limit(params, default_limit),
         {:ok, filters} <- parse_filters(Map.get(params, "filters", [])) do
      {:ok,
       %__MODULE__{
         sources: normalize_sources(Map.get(params, "sources")),
         signal: signal,
         from: from,
         to: to,
         filters: filters,
         raw: Map.get(params, "raw"),
         mode: mode,
         limit: limit,
         order: order,
         cursor: Map.get(params, "cursor")
       }}
    end
  end

  defp normalize_sources(nil), do: nil
  defp normalize_sources(list) when is_list(list), do: list

  defp fetch_enum(params, key, allowed, default \\ nil) do
    case Map.get(params, key) do
      nil when not is_nil(default) ->
        {:ok, default}

      nil ->
        {:error, {:missing_field, key}}

      value when is_binary(value) ->
        case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
          nil -> {:error, {:invalid_value, key, value, allowed}}
          atom -> {:ok, atom}
        end

      value ->
        {:error, {:invalid_type, key, value}}
    end
  end

  defp fetch_time(params, key, now) do
    case Map.get(params, key) do
      nil ->
        {:error, {:missing_field, key}}

      str when is_binary(str) ->
        case Time.parse(str, now) do
          {:ok, dt} -> {:ok, dt}
          {:error, reason} -> {:error, {:invalid_time, key, reason}}
        end

      value ->
        {:error, {:invalid_type, key, value}}
    end
  end

  defp fetch_limit(params, default) do
    case Map.get(params, "limit", default) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      other -> {:error, {:invalid_limit, other}}
    end
  end

  defp parse_filters(filters) when is_list(filters) do
    Enum.reduce_while(filters, {:ok, []}, fn f, {:ok, acc} ->
      case Filter.parse(f) do
        {:ok, filter} -> {:cont, {:ok, [filter | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp parse_filters(other), do: {:error, {:invalid_filters, other}}
end
