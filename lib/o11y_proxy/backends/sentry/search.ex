defmodule O11yProxy.Backends.Sentry.Search do
  @moduledoc """
  Pure Sentry search-query-string builder — no network I/O, exhaustively unit-tested
  (`test/o11y_proxy/backends/sentry/search_test.exs`). Mirrors `ClickHouse.SQL`'s and
  `VictoriaMetrics.PromQL`'s compile/execute split for the same reason: this is the seam
  that carries injection risk. Sentry's dialect has no SQL-style statements to smuggle,
  but a hostile value could still forge a second `field:value` token via an unescaped
  colon or quote — every value is double-quoted and escaped, never spliced raw, exactly
  like `PromQL`'s label-value handling.

  Only two canonical fields are filterable for v1 (see `.plans/03-adapters.md`):
  `severity` (`eq` only — Sentry's `level:` token is an exact match, not a range) and
  `body` (`contains` only — a bare quoted term does Sentry's free-text message search).
  `trace_id` (`eq`) is included for the future `/v1/context` fan-out even though nothing
  in the v1 `/v1/query` surface reaches it yet.
  """

  alias O11yProxy.Query

  @levels %{
    "trace" => "debug",
    "debug" => "debug",
    "info" => "info",
    "warn" => "warning",
    "error" => "error",
    "fatal" => "fatal"
  }

  @doc """
  Builds a Sentry structured search `query` string from canonical filters. An empty
  filter list compiles to an empty string — Sentry's API defaults an omitted `query`
  param to `is:unresolved` server-side, so the adapter leaves it unset rather than
  re-implementing that default.
  """
  @spec build_query([Query.Filter.t()]) :: {:ok, String.t()} | {:error, term()}
  def build_query(filters) do
    with {:ok, clauses} <- clauses(filters) do
      {:ok, Enum.join(clauses, " ")}
    end
  end

  defp clauses(filters) do
    filters
    |> Enum.reduce_while({:ok, []}, fn filter, {:ok, acc} ->
      case clause_for(filter) do
        {:ok, clause} -> {:cont, {:ok, [clause | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp clause_for(%{field: "severity", op: :eq, value: value}) do
    {:ok, "level:" <> quote_token(map_level(value))}
  end

  defp clause_for(%{field: "severity", op: op}), do: {:error, {:unsupported_operator, op}}

  defp clause_for(%{field: "trace_id", op: :eq, value: value}) do
    {:ok, "trace:" <> quote_token(value)}
  end

  defp clause_for(%{field: "trace_id", op: op}), do: {:error, {:unsupported_operator, op}}

  defp clause_for(%{field: "body", op: :contains, value: value}) do
    {:ok, quote_token(value)}
  end

  defp clause_for(%{field: "body", op: op}), do: {:error, {:unsupported_operator, op}}

  defp clause_for(%{field: field}), do: {:error, {:unknown_field, field}}

  @doc "Maps a canonical severity value onto Sentry's `level:` vocabulary."
  @spec map_level(term()) :: String.t()
  def map_level(value) do
    key = value |> to_string() |> String.downcase()
    Map.get(@levels, key, key)
  end

  # Sentry search values are double-quoted when they contain spaces/special characters;
  # quoting unconditionally is simpler and always safe. Backslash and quote are escaped,
  # in that order, same as O11yProxy.Backends.VictoriaMetrics.PromQL's label-value
  # escaping — a hostile value can only ever land inside the quotes, never end them early
  # or open a second `field:value` token.
  defp quote_token(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end
end
