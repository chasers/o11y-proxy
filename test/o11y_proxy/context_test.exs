defmodule O11yProxy.ContextTest do
  @moduledoc """
  Pure-logic tests for `/v1/context`'s two decision points: which entry kind a request is
  (`classify/1`, enforcing the "exactly one of" rule the OpenAPI schema only states in
  prose), and how stage two's metrics window/service get *derived* from stage one's
  results (`derive_window_and_service/1`) — the bit that makes "metrics for the owning
  service over the trace's window" work when metrics carry no trace ID.

  The fan-out itself is exercised end-to-end against live fake sources in
  `router_test.exs`.
  """

  use ExUnit.Case, async: true

  alias O11yProxy.{Context, Record}

  describe "classify/1" do
    test "recognizes each entry kind" do
      assert {:ok, {:trace_id, "abc"}} = Context.classify(%{"trace_id" => "abc"})
      assert {:ok, {:error_id, "ERR-1"}} = Context.classify(%{"error_id" => "ERR-1"})

      assert {:ok, {:service_window, "checkout-api", "now-1h", "now"}} =
               Context.classify(%{
                 "service" => "checkout-api",
                 "from" => "now-1h",
                 "to" => "now"
               })
    end

    test "rejects a request with no entry kind at all" do
      assert {:error, :empty_request} = Context.classify(%{})
    end

    test "rejects an incomplete service window" do
      assert {:error, :empty_request} = Context.classify(%{"service" => "checkout-api"})
      assert {:error, :empty_request} = Context.classify(%{"from" => "now-1h", "to" => "now"})
    end

    test "rejects more than one entry kind — 'exactly one of' is enforced, not assumed" do
      assert {:error, :ambiguous_request} =
               Context.classify(%{"trace_id" => "abc", "error_id" => "ERR-1"})

      assert {:error, :ambiguous_request} =
               Context.classify(%{"trace_id" => "abc", "service" => "checkout-api"})

      assert {:error, :ambiguous_request} =
               Context.classify(%{"error_id" => "ERR-1", "from" => "now-1h"})
    end

    test "treats blank strings as absent, not as a given value" do
      assert {:error, :empty_request} = Context.classify(%{"trace_id" => "   "})
      assert {:ok, {:trace_id, "abc"}} = Context.classify(%{"trace_id" => "abc", "service" => ""})
    end
  end

  describe "derive_window_and_service/1" do
    defp result(signal, records) do
      {%{name: "src", signal: signal},
       {:ok, %{records: records, native: "n", total: length(records)}}}
    end

    defp record(service, timestamp) do
      %Record{
        timestamp: timestamp,
        severity: :error,
        body: "boom",
        service: service,
        attributes: %{},
        source: "src"
      }
    end

    test "derives the service and a padded window spanning the matched records" do
      results = [
        result(:logs, [
          record("checkout-api", "2026-09-06T12:00:00Z"),
          record("checkout-api", "2026-09-06T12:05:00Z")
        ])
      ]

      assert {"checkout-api", from, to} = Context.derive_window_and_service(results)
      # 5 minutes of padding on each side of the matched span
      assert DateTime.compare(from, ~U[2026-09-06 11:55:00Z]) == :eq
      assert DateTime.compare(to, ~U[2026-09-06 12:10:00Z]) == :eq
    end

    test "prefers a trace span's service over a log's when both matched" do
      results = [
        result(:logs, [record("log-service", "2026-09-06T12:00:00Z")]),
        result(:traces, [record("trace-service", "2026-09-06T12:00:00Z")])
      ]

      assert {"trace-service", _from, _to} = Context.derive_window_and_service(results)
    end

    test "returns nil when nothing matched — stage two is skipped, no wasted metric queries" do
      assert Context.derive_window_and_service([result(:logs, [])]) == nil
      assert Context.derive_window_and_service([]) == nil
    end

    test "ignores failed sources rather than crashing on them" do
      results = [
        {%{name: "broken", signal: :logs}, {:error, :timeout}},
        result(:logs, [record("checkout-api", "2026-09-06T12:00:00Z")])
      ]

      assert {"checkout-api", _from, _to} = Context.derive_window_and_service(results)
    end

    test "returns nil when records carry no usable service" do
      assert Context.derive_window_and_service([
               result(:logs, [record("", "2026-09-06T12:00:00Z")])
             ]) == nil
    end
  end
end
