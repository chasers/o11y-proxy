defmodule O11yProxy.Shaping do
  @moduledoc """
  Response-shaping pass applied uniformly to both `/v1/query` and `/v1/context` from the
  router, right before `send_json` — the token-budget and security net,
  in one place so no response path can accidentally skip it.

  Four independent concerns, composed by `shape/2`:

    * **Redaction** — always, every mode. This daemon holds read credentials to
      production data and hands results to an LLM-driven caller; production logs contain
      secrets more often than anyone would like.
    * **Duplicate collapsing** and **long-attribute elision** — only for `:summary`/
      `:sample` (`:full` keeps raw values, since an agent
      that asked for full mode already opted into the cost).
    * **Byte ceiling** — `enforce_byte_ceiling/3`, applied separately by the caller since
      it needs the whole response envelope (to patch `meta.truncated`/`meta.returned`),
      not just a record list.
  """

  alias O11yProxy.Record

  @sensitive_keys ~w(authorization password token api_key cookie set_cookie)

  @doc """
  Redacts known-sensitive keys in an attributes map. Matches the last `.`/`-`/`_`/space
  -separated segment of a (lowercased) key against the sensitive set, so both a bare
  `Authorization` and a namespaced `http.request.header.authorization` are caught.
  `extra_keys` (from `defaults.redact_keys` in config) are merged in, same matching rule.

  Recurses into nested maps and lists. ClickHouse's `Map(String, String)` attribute
  columns are flat, but a JSON attribute column or a `raw`-mode projection is not, and a
  credential one level down (`attributes["headers"]["authorization"]`) is exactly the
  thing this is here to stop.
  """
  @spec redact(map(), [String.t()]) :: map()
  def redact(attributes, extra_keys \\ []) when is_map(attributes) do
    sensitive = MapSet.new(@sensitive_keys ++ Enum.map(extra_keys, &normalize_key/1))
    redact_value(attributes, sensitive)
  end

  defp redact_value(map, sensitive) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} ->
      if sensitive?(k, sensitive), do: {k, "[REDACTED]"}, else: {k, redact_value(v, sensitive)}
    end)
  end

  defp redact_value(list, sensitive) when is_list(list),
    do: Enum.map(list, &redact_value(&1, sensitive))

  defp redact_value(value, _sensitive), do: value

  # A key matches if either its whole normalized form, or just its last `_`-separated
  # segment, is in the sensitive set — the former lets a multi-word custom pattern (e.g.
  # `x_internal_secret`) match as a unit, the latter catches a namespaced key (e.g.
  # `http.request.header.authorization`) via its meaningful tail.
  defp sensitive?(key, sensitive) do
    normalized = normalize_key(key)
    last_segment = normalized |> String.split("_") |> List.last()
    normalized in sensitive or last_segment in sensitive
  end

  defp normalize_key(key) do
    key |> to_string() |> String.downcase() |> String.replace(~r/[-.\s]+/, "_")
  end

  @doc """
  Collapses records sharing `{severity, body, service}` into one, keeping the first
  occurrence's timestamp/attributes and adding `attributes["duplicate_count"]` — only
  set when there actually were duplicates, so the common (no-duplicate) case stays
  byte-identical. Order-preserving by first occurrence.
  """
  @spec collapse_duplicates([Record.t()]) :: [Record.t()]
  def collapse_duplicates(records) do
    if Enum.all?(records, &match?(%Record{}, &1)) do
      do_collapse_duplicates(records)
    else
      records
    end
  end

  defp do_collapse_duplicates(records) do
    records
    |> Enum.reduce({[], %{}}, fn record, {order, groups} ->
      key = {record.severity, record.body, record.service}

      case Map.fetch(groups, key) do
        {:ok, {seen_at, kept}} ->
          {order, Map.put(groups, key, {seen_at, %{kept | count: kept.count + 1}})}

        :error ->
          index = length(order)
          {[key | order], Map.put(groups, key, {index, %{record: record, count: 1}})}
      end
    end)
    |> then(fn {order, groups} ->
      order |> Enum.reverse() |> Enum.map(&rebuild_group(groups, &1))
    end)
  end

  defp rebuild_group(groups, key) do
    {_index, %{record: record, count: count}} = Map.fetch!(groups, key)
    if count > 1, do: put_duplicate_count(record, count), else: record
  end

  defp put_duplicate_count(record, count) do
    %{record | attributes: Map.put(record.attributes, "duplicate_count", count)}
  end

  @doc """
  Replaces attribute values over `max_bytes` with an `"[elided, N bytes]"` marker. Only
  binary values are measured/elided — a large nested map/list is left as-is rather than
  guessed at (this is the "stack traces and request bodies" case from
  `04-cross-cutting.md`, which are always strings in practice).
  """
  @spec elide_long_attributes(map(), pos_integer()) :: map()
  def elide_long_attributes(attributes, max_bytes \\ 500) when is_map(attributes) do
    Map.new(attributes, fn
      {k, v} when is_binary(v) ->
        if byte_size(v) > max_bytes do
          {k, "[elided, #{byte_size(v)} bytes]"}
        else
          {k, v}
        end

      {k, v} ->
        {k, v}
    end)
  end

  @doc """
  The umbrella pass: redact always; collapse duplicates and elide long attributes only
  for `:summary`/`:sample` mode. `extra_redact_keys` comes from `defaults.redact_keys`.

  Anything that isn't an `O11yProxy.Record` passes through untouched — `:summary` mode
  returns time-bucketed aggregate rows (`%{bucket:, severity:, service:, count:}`) and
  metrics return `MetricSeries` maps, neither of which has an `attributes` map to redact
  or a `body` to deduplicate against. Assuming otherwise 500s a real `:summary` query.
  """
  @spec shape([Record.t()], atom(), [String.t()]) :: [Record.t()]
  def shape(records, mode, extra_redact_keys \\ [])

  def shape(records, mode, extra_redact_keys) when mode in [:summary, :sample] do
    records
    |> Enum.map(fn
      %Record{} = record ->
        %{
          record
          | attributes: record.attributes |> elide_long_attributes() |> redact(extra_redact_keys)
        }

      other ->
        other
    end)
    |> collapse_duplicates()
  end

  def shape(records, _mode, extra_redact_keys) do
    Enum.map(records, fn
      %Record{} = record -> %{record | attributes: redact(record.attributes, extra_redact_keys)}
      other -> other
    end)
  end

  @doc """
  Enforces a byte ceiling on a full response envelope (already atom-keyed, ready for
  `Jason.encode!/1`). `list_keys` names which top-level keys hold record/series lists to
  trim from (e.g. `[:data]` for `/v1/query`, `[:trace, :logs, :metrics]` for
  `/v1/context`). On overflow, repeatedly drops the last element of whichever named list
  is currently longest until the encoded response fits, then sets `meta.truncated: true`
  and `meta.returned` to the post-trim total — `meta.total_matched` is left untouched,
  since it reflects what the backend actually matched, not what we chose to ship.
  """
  @spec enforce_byte_ceiling(map(), [atom()], pos_integer()) :: map()
  def enforce_byte_ceiling(response, list_keys, max_bytes \\ 64_000) do
    if fits?(response, max_bytes) do
      response
    else
      response
      |> trim_until_fits(list_keys, max_bytes)
      |> mark_truncated(list_keys)
    end
  end

  defp fits?(response, max_bytes), do: byte_size(Jason.encode!(response)) <= max_bytes

  # Estimates how much to drop from the encoded size and cuts that much in one pass,
  # rather than dropping a single record and re-encoding the whole envelope each time.
  # `limit` has no upper bound in `O11yProxy.Query`, so the naive loop is O(n²) encodes —
  # a `mode: full, limit: 20000` query that overflows the ceiling would burn minutes of
  # CPU inside the request. Each pass strictly shrinks the lists, so this terminates.
  defp trim_until_fits(response, list_keys, max_bytes) do
    size = byte_size(Jason.encode!(response))
    total = total_items(response, list_keys)

    if size <= max_bytes or total == 0 do
      response
    else
      # Keep a proportional share of what's there, minus a little slack for the
      # envelope's fixed overhead; never fewer than one fewer than we have now.
      keep = min(total - 1, max(0, floor(total * max_bytes / size) - 1))
      response |> trim_to(list_keys, keep) |> trim_until_fits(list_keys, max_bytes)
    end
  end

  # Trims the named lists to `keep` items in total by capping each list at the same
  # length — i.e. taking from the longest lists first, so a bundle stays as balanced
  # across signals as the budget allows — in one pass per list rather than one drop at a
  # time.
  defp trim_to(response, list_keys, keep) do
    lengths = Enum.map(list_keys, fn key -> length(Map.get(response, key, [])) end)
    cap = length_cap(lengths, keep)

    Enum.reduce(list_keys, response, fn key, acc ->
      Map.update(acc, key, [], fn list -> Enum.take(list, cap) end)
    end)
  end

  # Largest per-list length whose capped total still fits within `keep`.
  defp length_cap(lengths, keep) do
    max_len = Enum.max(lengths, fn -> 0 end)

    Enum.reduce_while(0..max_len//1, 0, fn cap, last_fitting ->
      capped_total = Enum.sum_by(lengths, &min(&1, cap))
      if capped_total > keep, do: {:halt, last_fitting}, else: {:cont, cap}
    end)
  end

  defp total_items(response, list_keys) do
    Enum.reduce(list_keys, 0, fn key, acc -> acc + length(Map.get(response, key, [])) end)
  end

  # `returned` counts the singular `error` too when the response has one (a truncated
  # /v1/context bundle that still ships an issue must not report `returned: 0`).
  defp mark_truncated(response, list_keys) do
    error_count = if Map.get(response, :error), do: 1, else: 0

    Map.update(response, :meta, %{}, fn meta ->
      meta
      |> Map.put(:truncated, true)
      |> Map.put(:returned, total_items(response, list_keys) + error_count)
    end)
  end
end
