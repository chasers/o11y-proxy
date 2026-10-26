defmodule O11yProxy.Auth.Claims do
  @moduledoc """
  Reads values out of a verified JWT claims map by a configured path such as
  `"o11y.role"`. Pure, so the lookup rules can be tested without a token or an issuer.

  A path is split on `.`, but a segment is matched greedily against the *longest* key that
  exists at that level first. Issuers commonly put dots inside a single claim name —
  namespaced claims such as `"https://example.com/roles"` are the norm on several hosted
  providers — and a naive split would make those claims unreachable from config.
  """

  @doc """
  Looks up `path` in `claims`. Returns `{:ok, value}` or `:error` when any segment is
  missing or a non-map is reached before the path is exhausted.
  """
  @spec get(map(), String.t()) :: {:ok, term()} | :error
  def get(claims, path) when is_map(claims) and is_binary(path) do
    walk(claims, String.split(path, "."))
  end

  defp walk(value, []), do: {:ok, value}

  defp walk(map, segments) when is_map(map) do
    Enum.find_value(length(segments)..1//-1, :error, fn take ->
      {head, rest} = Enum.split(segments, take)

      case Map.fetch(map, Enum.join(head, ".")) do
        {:ok, value} -> continue(walk(value, rest))
        :error -> nil
      end
    end)
  end

  defp walk(_not_a_map, _segments), do: :error

  # `Enum.find_value/3` treats `nil` as "keep looking", so a found-but-deeper-miss has to
  # be turned into `nil` here for the next, shorter key prefix to get its turn.
  defp continue(:error), do: nil
  defp continue(found), do: found

  @doc """
  Normalises a claim that may be a single string or a list of strings — the two shapes
  issuers use for `aud` and for role claims. Anything else is `:error`.
  """
  @spec strings(term()) :: {:ok, [String.t()]} | :error
  def strings(value) when is_binary(value), do: {:ok, [value]}

  def strings(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: :error
  end

  def strings(_other), do: :error

  @doc """
  Normalises a claim used as a policy's allowed values: one scalar or a list of scalars
  (strings, integers, booleans). Nested maps and lists are refused, since they cannot be
  compared against a filter value.
  """
  @spec scalars(term()) :: {:ok, [String.t() | integer() | boolean()]} | :error
  def scalars(values) when is_list(values) do
    if Enum.all?(values, &scalar?/1), do: {:ok, values}, else: :error
  end

  def scalars(value) do
    if scalar?(value), do: {:ok, [value]}, else: :error
  end

  defp scalar?(value), do: is_binary(value) or is_integer(value) or is_boolean(value)
end
