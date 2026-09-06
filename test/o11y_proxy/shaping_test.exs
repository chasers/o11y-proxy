defmodule O11yProxy.ShapingTest do
  use ExUnit.Case, async: true

  alias O11yProxy.{Record, Shaping}

  defp record(overrides) do
    struct(
      %Record{
        timestamp: "2026-09-06T12:00:00Z",
        severity: :error,
        body: "connection pool timeout",
        service: "checkout-api",
        attributes: %{},
        source: "app_logs"
      },
      overrides
    )
  end

  describe "redact/2" do
    test "redacts built-in sensitive keys, case-insensitively" do
      attrs = %{"Authorization" => "Bearer xyz", "SET-COOKIE" => "sid=1", "safe" => "keep me"}
      redacted = Shaping.redact(attrs)

      assert redacted["Authorization"] == "[REDACTED]"
      assert redacted["SET-COOKIE"] == "[REDACTED]"
      assert redacted["safe"] == "keep me"
    end

    test "matches a namespaced key by its last segment" do
      attrs = %{"http.request.header.authorization" => "Bearer xyz"}
      assert Shaping.redact(attrs)["http.request.header.authorization"] == "[REDACTED]"
    end

    test "does not over-redact a key that merely contains a sensitive word mid-token" do
      attrs = %{"token_count" => 42}
      assert Shaping.redact(attrs)["token_count"] == 42
    end

    test "merges in configured extra keys" do
      attrs = %{"x-internal-secret" => "shh"}
      assert Shaping.redact(attrs, ["x_internal_secret"])["x-internal-secret"] == "[REDACTED]"
    end

    test "recurses into nested maps — a credential one level down still gets redacted" do
      attrs = %{"http" => %{"request" => %{"headers" => %{"authorization" => "Bearer xyz"}}}}
      redacted = Shaping.redact(attrs)
      assert redacted["http"]["request"]["headers"]["authorization"] == "[REDACTED]"
    end

    test "recurses into lists of maps" do
      attrs = %{"events" => [%{"cookie" => "sid=1"}, %{"safe" => "ok"}]}
      redacted = Shaping.redact(attrs)
      assert [%{"cookie" => "[REDACTED]"}, %{"safe" => "ok"}] = redacted["events"]
    end
  end

  describe "collapse_duplicates/1" do
    test "collapses records sharing severity/body/service, keeping first occurrence" do
      records = [
        record(%{timestamp: "t1"}),
        record(%{timestamp: "t2"}),
        record(%{timestamp: "t3", body: "different"})
      ]

      collapsed = Shaping.collapse_duplicates(records)

      assert [_, _] = collapsed
      assert Enum.at(collapsed, 0).timestamp == "t1"
      assert Enum.at(collapsed, 0).attributes["duplicate_count"] == 2
      assert Enum.at(collapsed, 1).timestamp == "t3"
      refute Map.has_key?(Enum.at(collapsed, 1).attributes, "duplicate_count")
    end

    test "does not add duplicate_count when there is nothing to collapse" do
      records = [record(%{body: "a"}), record(%{body: "b"})]
      collapsed = Shaping.collapse_duplicates(records)
      assert Enum.all?(collapsed, &(not Map.has_key?(&1.attributes, "duplicate_count")))
    end

    test "preserves first-occurrence order across non-adjacent duplicates" do
      records = [
        record(%{timestamp: "t1", body: "a"}),
        record(%{timestamp: "t2", body: "b"}),
        record(%{timestamp: "t3", body: "a"})
      ]

      collapsed = Shaping.collapse_duplicates(records)
      assert Enum.map(collapsed, & &1.body) == ["a", "b"]
      assert Enum.find(collapsed, &(&1.body == "a")).attributes["duplicate_count"] == 2
    end
  end

  describe "elide_long_attributes/2" do
    test "elides a binary value over the byte threshold" do
      big = String.duplicate("a", 600)
      attrs = %{"stack" => big, "short" => "ok"}
      elided = Shaping.elide_long_attributes(attrs, 500)

      assert elided["stack"] == "[elided, 600 bytes]"
      assert elided["short"] == "ok"
    end

    test "leaves non-binary values untouched regardless of size" do
      attrs = %{"count" => 42, "nested" => %{"a" => 1}}
      assert Shaping.elide_long_attributes(attrs, 1) == attrs
    end
  end

  describe "shape/3" do
    test "summary/sample mode redacts, elides, and collapses" do
      big = String.duplicate("x", 600)

      records = [
        record(%{attributes: %{"token" => "secret", "stack" => big}}),
        record(%{attributes: %{"token" => "secret", "stack" => big}})
      ]

      [shaped] = Shaping.shape(records, :sample)
      assert shaped.attributes["token"] == "[REDACTED]"
      assert shaped.attributes["stack"] =~ "[elided"
      assert shaped.attributes["duplicate_count"] == 2
    end

    test "full mode redacts but does not collapse or elide" do
      big = String.duplicate("x", 600)

      records = [
        record(%{attributes: %{"token" => "secret", "stack" => big}}),
        record(%{attributes: %{"token" => "secret", "stack" => big}})
      ]

      shaped = Shaping.shape(records, :full)
      assert [_, _] = shaped
      assert Enum.all?(shaped, &(&1.attributes["token"] == "[REDACTED]"))
      assert Enum.all?(shaped, &(&1.attributes["stack"] == big))
    end
  end

  describe "shape/3 with non-record rows" do
    # :summary mode returns time-bucketed aggregates, not canonical records — shaping
    # must not assume an `attributes` map exists. This crashed a real :summary query
    # before the guard was added.
    @summary_rows [
      %{bucket: "2026-09-06T12:00:00Z", severity: :error, service: "checkout-api", count: 42},
      %{bucket: "2026-09-06T12:01:00Z", severity: :error, service: "checkout-api", count: 7}
    ]

    test "passes summary aggregate rows through untouched in summary mode" do
      assert Shaping.shape(@summary_rows, :summary) == @summary_rows
    end

    test "passes MetricSeries maps through untouched" do
      series = [%{name: "http_requests_total", labels: %{"service" => "x"}, points: [[1, 2.0]]}]
      assert Shaping.shape(series, :full) == series
    end

    test "collapse_duplicates/1 leaves a non-record list alone" do
      assert Shaping.collapse_duplicates(@summary_rows) == @summary_rows
    end
  end

  describe "enforce_byte_ceiling/3" do
    test "leaves a response under budget untouched" do
      response = %{data: [%{body: "small"}], meta: %{returned: 1, truncated: false}}
      assert Shaping.enforce_byte_ceiling(response, [:data], 64_000) == response
    end

    test "trims the largest list until under budget and marks meta.truncated" do
      big_body = String.duplicate("a", 200)
      data = for i <- 1..10, do: %{body: big_body, i: i}
      response = %{data: data, meta: %{returned: 10, truncated: false, total_matched: 10}}

      shaped = Shaping.enforce_byte_ceiling(response, [:data], 800)

      assert Enum.count_until(shaped.data, 10) < 10
      assert shaped.meta.truncated == true
      assert shaped.meta.returned == length(shaped.data)
      assert shaped.meta.total_matched == 10
      assert byte_size(Jason.encode!(shaped)) <= 800 or shaped.data == []
    end

    test "counts the singular error in meta.returned when truncating a bundle" do
      big_body = String.duplicate("a", 200)
      logs = for i <- 1..10, do: %{body: big_body, i: i}

      response = %{
        logs: logs,
        trace: [],
        metrics: [],
        error: %{body: "the issue"},
        meta: %{returned: 11, truncated: false}
      }

      shaped = Shaping.enforce_byte_ceiling(response, [:trace, :logs, :metrics], 900)

      assert shaped.meta.truncated == true
      assert shaped.meta.returned == length(shaped.logs) + 1
      assert shaped.error != nil
    end

    test "trims a large overflow without re-encoding once per dropped record" do
      # Regression guard for the O(n^2) trim: 5k records must not take pathological time.
      big_body = String.duplicate("a", 100)
      data = for i <- 1..5_000, do: %{body: big_body, i: i}
      response = %{data: data, meta: %{returned: 5_000, truncated: false}}

      {micros, shaped} =
        :timer.tc(fn -> Shaping.enforce_byte_ceiling(response, [:data], 10_000) end)

      assert shaped.meta.truncated == true
      assert byte_size(Jason.encode!(shaped)) <= 10_000
      assert micros < 3_000_000, "byte-ceiling trim took #{div(micros, 1000)}ms — too slow"
    end

    test "trims from whichever named list is currently largest, across multiple lists" do
      big_body = String.duplicate("a", 100)
      trace = for i <- 1..5, do: %{body: big_body, i: i}
      logs = for i <- 1..1, do: %{body: big_body, i: i}
      response = %{trace: trace, logs: logs, meta: %{returned: 6, truncated: false}}

      shaped = Shaping.enforce_byte_ceiling(response, [:trace, :logs], 400)

      assert Enum.count_until(shaped.trace, 5) < 5
      assert shaped.meta.truncated == true
    end
  end
end
