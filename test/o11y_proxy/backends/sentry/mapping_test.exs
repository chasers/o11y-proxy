defmodule O11yProxy.Backends.Sentry.MappingTest do
  @moduledoc """
  Exercises `O11yProxy.Backends.Sentry.issue_to_record/2` — the pure issue->canonical
  mapping — against a captured-and-scrubbed real issue-list response. Shape and field
  names are exactly what `GET /organizations/{org}/issues/` returned live on
  2026-09-06; every identifying value (org, project, ids, culprit path, error text) has
  been replaced with fiction from the same "checkout-api" / "payments-db" universe the
  rest of the fixtures use. No network access needed to run this test.
  """

  use ExUnit.Case, async: true

  alias O11yProxy.Backends.Sentry

  # Captured shape: GET /organizations/{org}/issues/?project=&statsPeriod=14d&limit=1
  # (scrubbed — see moduledoc)
  @issue %{
    "id" => "1234567890",
    "shortId" => "CHECKOUT-API-42",
    "title" => "*errors.errorString: request timeout after 30s",
    "culprit" => "github.com/acme/checkout-api/internal/payments in (*Handler).ProcessCharge",
    "level" => "fatal",
    "count" => "832",
    "firstSeen" => "2026-08-26T21:58:04Z",
    "lastSeen" => "2026-09-06T12:51:10Z",
    "permalink" => "https://acme.sentry.io/issues/1234567890/",
    "metadata" => %{
      "filename" => "internal/payments/handler.go",
      "function" => "ProcessCharge",
      "type" => "errors.errorString",
      "value" => "request timeout after 30s"
    }
  }

  @state %{project: "checkout-api"}

  test "maps timestamp from lastSeen, RFC3339 UTC" do
    record = Sentry.issue_to_record(@issue, @state)
    assert record.timestamp == "2026-09-06T12:51:10Z"
    assert {:ok, _dt, 0} = DateTime.from_iso8601(record.timestamp)
  end

  test "falls back to firstSeen when lastSeen is absent" do
    record = Sentry.issue_to_record(Map.delete(@issue, "lastSeen"), @state)
    assert record.timestamp == "2026-08-26T21:58:04Z"
  end

  test "maps level -> canonical severity" do
    assert Sentry.issue_to_record(@issue, @state).severity == :fatal
    assert Sentry.issue_to_record(%{@issue | "level" => "warning"}, @state).severity == :warn
    assert Sentry.issue_to_record(%{@issue | "level" => "unknown"}, @state).severity == :info
    assert Sentry.issue_to_record(Map.delete(@issue, "level"), @state).severity == :info
  end

  test "maps title -> body" do
    assert Sentry.issue_to_record(@issue, @state).body ==
             "*errors.errorString: request timeout after 30s"
  end

  test "falls back to metadata.value, then culprit, when title is absent" do
    no_title = Map.delete(@issue, "title")
    assert Sentry.issue_to_record(no_title, @state).body == "request timeout after 30s"

    no_title_no_metadata = Map.drop(no_title, ["metadata"])
    assert Sentry.issue_to_record(no_title_no_metadata, @state).body =~ "ProcessCharge"
  end

  test "service comes from the configured project, not the issue payload" do
    assert Sentry.issue_to_record(@issue, @state).service == "checkout-api"
  end

  test "trace_id and span_id are nil at this stage — filled in by the enrichment fetch" do
    record = Sentry.issue_to_record(@issue, @state)
    assert record.trace_id == nil
    assert record.span_id == nil
  end

  test "attributes carries the issue identity fields, for the trace_id enrichment fetch and debugging" do
    record = Sentry.issue_to_record(@issue, @state)

    assert record.attributes == %{
             "issue_id" => "1234567890",
             "short_id" => "CHECKOUT-API-42",
             "culprit" =>
               "github.com/acme/checkout-api/internal/payments in (*Handler).ProcessCharge",
             "count" => "832",
             "permalink" => "https://acme.sentry.io/issues/1234567890/"
           }
  end

  test "source is left blank — O11yProxy.Sources stamps the configured source name" do
    assert Sentry.issue_to_record(@issue, @state).source == ""
  end

  test "the mapped record passes the canonical record contract" do
    O11yProxy.BackendCase.assert_canonical_record!(Sentry.issue_to_record(@issue, @state))
  end
end
