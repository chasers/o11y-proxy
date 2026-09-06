defmodule O11yProxy.Backends.VictoriaMetrics.PromQL do
  @moduledoc """
  Pure MetricsQL-building helpers — no network I/O, exhaustively unit-tested
  (`test/o11y_proxy/backends/victoria_metrics/promql_test.exs`). Mirrors
  `O11yProxy.Backends.ClickHouse.SQL`'s split for the same reason: this is the seam that
  carries injection/correctness risk, so it stays pure and gets exhaustive tests with no
  network mocking. See "compile/execute split" in `.plans/02-backend-behaviour.md`.
  """

  alias O11yProxy.Query

  @doc """
  Builds a MetricsQL selector (`name{label="v",...}`) from canonical filters. An optional
  `{"field": "name", "op": "eq", ...}` filter supplies the metric name; every other
  filter must be `labels.<name>` with `eq`/`neq`/`regex`. A bare `{label="v"}` selector
  with no name is valid PromQL/MetricsQL and is allowed; a selector with neither a name
  nor any label matcher is not. Fails rather than silently dropping a filter it can't
  express — an `eq`/`neq`/`regex` value is always quoted and escaped, never spliced raw.
  """
  @spec build_selector([Query.Filter.t()]) :: {:ok, String.t()} | {:error, term()}
  def build_selector(filters) do
    with {:ok, name, rest} <- extract_name(filters),
         {:ok, matchers} <- build_matchers(rest) do
      if name == "" and matchers == "" do
        {:error,
         {:invalid_query, "at least a `name` filter or one `labels.*` filter is required"}}
      else
        {:ok, "#{name}#{matchers}"}
      end
    end
  end

  defp extract_name(filters) do
    case Enum.split_with(filters, &(&1.field == "name")) do
      {[%{op: :eq, value: name}], rest} when is_binary(name) -> {:ok, name, rest}
      {[%{op: op}], _rest} -> {:error, {:unsupported_operator, op}}
      {[], rest} -> {:ok, "", rest}
      {_multiple, _rest} -> {:error, {:invalid_query, "only one `name` filter is allowed"}}
    end
  end

  defp build_matchers([]), do: {:ok, ""}

  defp build_matchers(filters) do
    with {:ok, clauses} <- matcher_clauses(filters) do
      {:ok, "{" <> Enum.join(clauses, ",") <> "}"}
    end
  end

  defp matcher_clauses(filters) do
    Enum.reduce_while(filters, {:ok, []}, fn filter, {:ok, acc} ->
      case matcher_clause(filter) do
        {:ok, clause} -> {:cont, {:ok, [clause | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp matcher_clause(%{field: "labels." <> label, op: op, value: value}) do
    case op do
      :eq -> {:ok, ~s(#{label}="#{escape(value)}")}
      :neq -> {:ok, ~s(#{label}!="#{escape(value)}")}
      :regex -> {:ok, ~s(#{label}=~"#{escape(value)}")}
      other -> {:error, {:unsupported_operator, other}}
    end
  end

  defp matcher_clause(%{field: field}), do: {:error, {:unknown_field, field}}

  # PromQL label-value strings are double-quoted; escape backslash and quote so a
  # hostile value can only ever land inside the quotes, never end them early.
  defp escape(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  @doc "Step width (seconds) targeting roughly `target_points` samples across the window."
  @spec step_seconds(DateTime.t(), DateTime.t(), pos_integer()) :: pos_integer()
  def step_seconds(from, to, target_points) do
    window = max(DateTime.diff(to, from, :second), 1)
    max(div(window, max(target_points, 1)), 1)
  end
end
