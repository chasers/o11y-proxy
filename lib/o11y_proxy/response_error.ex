defmodule O11yProxy.ResponseError do
  @moduledoc """
  Maps an internal error reason onto the `ResponseError` shape documented in
  `priv/static/openapi.json` — `%{source, code, message, retry_after_ms}`, where `code` is
  one of the documented enum values and nothing else.

  Shared by `/v1/query` (`O11yProxy.Router`) and `/v1/context` (`O11yProxy.Context`) so
  the two can't drift; `errors` being a peer of the data is what makes partial failure the
  normal path, which only works if the codes are
  consistent and machine-readable across both.
  """

  @doc "Builds one `ResponseError` entry for a source that failed."
  @spec build(String.t(), term()) :: map()
  def build(source, reason), do: Map.put(shape(reason), :source, source)

  # An open breaker is deliberately reported as `unreachable` rather than a new code:
  # from the caller's side that's exactly what it is (we're refusing to talk to a source
  # we believe is down), and the documented enum is a contract, not a suggestion.
  defp shape({:circuit_open, retry_after_ms}) do
    %{
      code: "unreachable",
      message: "circuit breaker open after repeated failures; not querying this source yet",
      retry_after_ms: retry_after_ms
    }
  end

  defp shape({:rate_limited, retry_after_ms}) do
    %{
      code: "rate_limited",
      message: "rate limited by the backend",
      retry_after_ms: retry_after_ms
    }
  end

  defp shape(:timeout) do
    %{code: "timeout", message: "source did not respond within the deadline", retry_after_ms: nil}
  end

  defp shape({:unsupported_operator, op}) do
    %{
      code: "unsupported_operator",
      message: "this source cannot express the #{inspect(op)} operator",
      retry_after_ms: nil
    }
  end

  defp shape({:unknown_field, field}) do
    %{
      code: "invalid_query",
      message: "this source has no filterable field #{inspect(field)}",
      retry_after_ms: nil
    }
  end

  defp shape({:invalid_cursor, detail}) do
    %{code: "invalid_query", message: "invalid cursor: #{inspect(detail)}", retry_after_ms: nil}
  end

  defp shape({:invalid_raw_query, detail}) do
    %{code: "invalid_query", message: "invalid raw query: #{detail}", retry_after_ms: nil}
  end

  defp shape({:raw_not_allowed, detail}) do
    %{code: "invalid_query", message: detail, retry_after_ms: nil}
  end

  defp shape({:invalid_query, detail}) do
    %{code: "invalid_query", message: to_string(detail), retry_after_ms: nil}
  end

  defp shape({unreachable, detail})
       when unreachable in [
              :clickhouse_unreachable,
              :victoriametrics_unreachable,
              :sentry_unreachable
            ] do
    %{code: "unreachable", message: to_string(detail), retry_after_ms: nil}
  end

  defp shape(:not_found) do
    %{code: "invalid_query", message: "no such source", retry_after_ms: nil}
  end

  defp shape(reason) do
    %{code: "internal", message: inspect(reason), retry_after_ms: nil}
  end
end
