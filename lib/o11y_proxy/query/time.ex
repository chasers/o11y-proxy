defmodule O11yProxy.Query.Time do
  @moduledoc """
  Parses the `from`/`to` time fields accepted throughout the agent contract: either an
  RFC3339 timestamp or a relative expression anchored on `now`, e.g. `"now"`, `"now-15m"`,
  `"now-1h"`, `"now-7d"`.
  """

  @unit_seconds %{"s" => 1, "m" => 60, "h" => 3600, "d" => 86_400, "w" => 604_800}

  @relative_re ~r/^now(?:([-+])(\d+)([smhdw]))?$/

  @doc """
  Resolves a time expression to a `DateTime` in UTC, anchored on `now` (defaults to the
  current time, injectable for tests).
  """
  @spec parse(String.t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, term()}
  def parse(str, now \\ DateTime.utc_now())

  def parse(str, now) when is_binary(str) do
    case Regex.run(@relative_re, str) do
      [_] ->
        {:ok, now}

      [_, sign, digits, unit] ->
        seconds = String.to_integer(digits) * Map.fetch!(@unit_seconds, unit)
        delta = if sign == "-", do: -seconds, else: seconds
        {:ok, DateTime.add(now, delta, :second)}

      nil ->
        parse_absolute(str)
    end
  end

  @duration_re ~r/^(\d+)([smhdw])$/

  @doc """
  Parses a duration such as `"15m"` or `"7d"` into seconds, using the same units as the
  relative `now-<n><unit>` form. Zero is refused: a cap of no time at all is a mistake.
  """
  @spec duration_seconds(String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def duration_seconds(str) when is_binary(str) do
    case Regex.run(@duration_re, str) do
      [_, digits, unit] ->
        case String.to_integer(digits) * Map.fetch!(@unit_seconds, unit) do
          0 -> {:error, {:invalid_duration, str}}
          seconds -> {:ok, seconds}
        end

      _ ->
        {:error, {:invalid_duration, str}}
    end
  end

  defp parse_absolute(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
      {:error, reason} -> {:error, {:invalid_timestamp, str, reason}}
    end
  end
end
