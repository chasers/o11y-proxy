defmodule O11yProxy.QueryTest do
  use ExUnit.Case, async: true

  alias O11yProxy.Query

  @now ~U[2026-09-05 20:00:00Z]

  test "parses a minimal valid request with defaults filled in" do
    assert {:ok, %Query{} = q} =
             Query.parse(%{"signal" => "logs", "from" => "now-1h", "to" => "now"}, now: @now)

    assert q.signal == :logs
    assert q.from == ~U[2026-09-05 19:00:00Z]
    assert q.to == @now
    assert q.mode == :summary
    assert q.order == :desc
    assert q.limit == 50
    assert q.filters == []
    assert q.sources == nil
  end

  test "parses filters and honors overrides" do
    params = %{
      "sources" => ["app_logs"],
      "signal" => "logs",
      "from" => "now-1h",
      "to" => "now",
      "filters" => [
        %{"field" => "severity", "op" => "gte", "value" => "error"},
        %{"field" => "service", "op" => "eq", "value" => "checkout-api"}
      ],
      "mode" => "sample",
      "limit" => 20,
      "order" => "asc"
    }

    assert {:ok, %Query{} = q} = Query.parse(params, now: @now)
    assert q.sources == ["app_logs"]
    assert q.mode == :sample
    assert q.limit == 20
    assert q.order == :asc
    assert [%Query.Filter{field: "severity", op: :gte, value: "error"}, _] = q.filters
  end

  test "raw replaces filters and is passed through untouched" do
    params = %{"signal" => "metrics", "from" => "now-1h", "to" => "now", "raw" => "rate(x[5m])"}
    assert {:ok, %Query{raw: "rate(x[5m])", filters: []}} = Query.parse(params, now: @now)
  end

  test "rejects an unknown signal" do
    assert {:error, {:invalid_value, "signal", "bogus", _}} =
             Query.parse(%{"signal" => "bogus", "from" => "now-1h", "to" => "now"}, now: @now)
  end

  test "rejects a missing required field" do
    assert {:error, {:missing_field, "from"}} =
             Query.parse(%{"signal" => "logs", "to" => "now"}, now: @now)
  end

  test "rejects an unsupported filter operator" do
    params = %{
      "signal" => "logs",
      "from" => "now-1h",
      "to" => "now",
      "filters" => [%{"field" => "body", "op" => "nope", "value" => "x"}]
    }

    assert {:error, {:unsupported_operator, "nope"}} = Query.parse(params, now: @now)
  end

  test "rejects a non-positive limit" do
    params = %{"signal" => "logs", "from" => "now-1h", "to" => "now", "limit" => 0}
    assert {:error, {:invalid_limit, 0}} = Query.parse(params, now: @now)
  end
end
