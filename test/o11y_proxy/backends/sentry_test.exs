defmodule O11yProxy.Backends.SentryTest do
  @moduledoc """
  Runs `O11yProxy.BackendCase` against the real adapter and a real Sentry org. Excluded
  by default (see `test/test_helper.exs`) since it needs a live `SENTRY_AUTH_TOKEN` —
  unlike ClickHouse/VictoriaMetrics there's no dockerizable stand-in for Sentry itself.

  To run for real (needs `org:read`-or-broader scope — see `.plans/03-adapters.md`):

      cp .env.sample .env   # fill in SENTRY_AUTH_TOKEN / SENTRY_ORG / SENTRY_PROJECT
      set -a; source .env; set +a
      mix test --include sentry test/o11y_proxy/backends/sentry_test.exs
  """

  use O11yProxy.BackendCase,
    backend: O11yProxy.Backends.Sentry,
    moduletag: :sentry,
    valid_config: [
      org: System.get_env("SENTRY_ORG", "acme"),
      project: System.get_env("SENTRY_PROJECT", "checkout-api"),
      token: System.get_env("SENTRY_AUTH_TOKEN", "unset"),
      allow_raw: true
    ],
    invalid_config: [org: "acme", project: 123, token: "unset"],
    queries: [
      %O11yProxy.Query{
        signal: :errors,
        from: DateTime.add(DateTime.utc_now(), -3600, :second),
        to: DateTime.add(DateTime.utc_now(), 3600, :second),
        mode: :full,
        limit: 5,
        filters: [%O11yProxy.Query.Filter{field: "severity", op: :eq, value: "error"}]
      },
      %O11yProxy.Query{
        signal: :errors,
        from: DateTime.add(DateTime.utc_now(), -3600, :second),
        to: DateTime.add(DateTime.utc_now(), 3600, :second),
        mode: :full,
        limit: 5,
        filters: [%O11yProxy.Query.Filter{field: "body", op: :contains, value: "timeout"}]
      }
    ],
    time_bound?: fn native -> Map.has_key?(native, :from) and Map.has_key?(native, :to) end,
    limit_present?: fn native, query -> native.limit == query.limit end,
    value_isolated?: fn native, _value ->
      # Same structural check as PromQLTest: after removing escaped `\\`/`\"` pairs,
      # exactly the two bare quotes wrapping our single filter's value should remain —
      # a hostile value cannot forge a second `field:value` token or end the string early.
      stripped =
        native.query
        |> String.replace("\\\\", "")
        |> String.replace("\\\"", "")

      stripped |> String.replace(~r/[^"]/, "") |> String.length() == 2
    end
end
