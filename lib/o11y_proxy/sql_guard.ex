defmodule O11yProxy.SQLGuard do
  @moduledoc """
  Shared guardrail for the `raw` escape hatch on SQL-speaking adapters: a caller-supplied
  query string must be a single `SELECT` (optionally with a leading `WITH`/CTE) and must
  not contain write or DDL keywords.

  Defense in depth, never the real boundary — that is a read-only ClickHouse user, or
  DuckDB's `disabled_filesystems` plus `lock_configuration`. But a client typo or a
  prompt-injected write statement should fail here first, before it reaches an engine at
  all.

  The write-keyword list is per-dialect because the dangerous verbs are: ClickHouse has
  `ATTACH`/`EXCHANGE`/`KILL`, DuckDB has `COPY`/`INSTALL`/`LOAD`/`PRAGMA`. Passing the
  list in rather than unioning both keeps each adapter's rejection honest — a query
  refused for an S3 source names a keyword that actually means something to DuckDB.
  """

  @doc """
  Validates that `sql` is a single read-only `SELECT`.

  `write_keywords` is the dialect's list of forbidden verbs, matched case-insensitively on
  word boundaries.
  """
  @spec validate_single_select(String.t(), [String.t()]) ::
          :ok | {:error, {:invalid_raw_query, String.t()}}
  def validate_single_select(sql, write_keywords)
      when is_binary(sql) and is_list(write_keywords) do
    trimmed = String.trim(sql)
    upcased = String.upcase(trimmed)

    cond do
      trimmed == "" ->
        {:error, {:invalid_raw_query, "empty query"}}

      not (String.starts_with?(upcased, "SELECT") or String.starts_with?(upcased, "WITH")) ->
        {:error,
         {:invalid_raw_query,
          "only a single SELECT (optionally with a WITH/CTE prefix) is allowed"}}

      has_multiple_statements?(trimmed) ->
        {:error, {:invalid_raw_query, "only a single statement is allowed"}}

      contains_write_keyword?(upcased, write_keywords) ->
        {:error, {:invalid_raw_query, "write/DDL keywords are not allowed in a raw query"}}

      true ->
        :ok
    end
  end

  defp has_multiple_statements?(sql) do
    sql |> String.trim_trailing() |> String.trim_trailing(";") |> String.contains?(";")
  end

  defp contains_write_keyword?(upcased, write_keywords) do
    Enum.any?(write_keywords, &Regex.match?(~r/\b#{&1}\b/, upcased))
  end
end
