# o11y-proxy

An agent-friendly observability proxy in Elixir. One HTTP+JSON interface over Sentry,
ClickHouse, and VictoriaMetrics (Logflare/BigQuery deferred), so an agent can debug
production without learning three query dialects.

Status: ClickHouse, VictoriaMetrics, and Sentry adapters implemented and passing their
contract tests (Phases 0-4, see `.plans/05-roadmap.md`) — `/v1/query` is live for a single
source at a time. Cross-backend correlation (`/v1/context`, shown below) is still
aspirational; fan-out lands in Phase 5.

## Example queries

Pseudo-requests against the canonical query API, one per v1 backend.

### ClickHouse logs — summary

Schema matches ClickStack's real `otel_logs` table (verified against
[ClickHouse's docs](https://clickhouse.com/docs/clickstack/ingesting-data/schemas#logs),
2026-09-06) — table name and columns below, not just an OTel-standard guess.

```json
POST /v1/query
{
  "sources": ["app_logs"],
  "signal": "logs",
  "from": "now-1h", "to": "now",
  "filters": [
    {"field": "severity", "op": "gte", "value": "error"},
    {"field": "service", "op": "eq", "value": "checkout-api"}
  ],
  "mode": "summary",
  "limit": 50
}
```

Native (`app_logs`):
```sql
SELECT toStartOfInterval(Timestamp, INTERVAL 60 SECOND) AS bucket,
       SeverityText, ServiceName, count()
FROM otel.otel_logs
WHERE Timestamp BETWEEN {from:DateTime64} AND {to:DateTime64}
  AND SeverityText >= {severity:String}
  AND ServiceName = {service:String}
GROUP BY bucket, SeverityText, ServiceName
ORDER BY bucket DESC
LIMIT 50
```

### ClickHouse traces — sample

```json
POST /v1/query
{
  "sources": ["otel_traces"],
  "signal": "traces",
  "from": "now-15m", "to": "now",
  "filters": [
    {"field": "service", "op": "eq", "value": "checkout-api"},
    {"field": "attributes.duration_ms", "op": "gte", "value": 1000}
  ],
  "mode": "sample",
  "limit": 20
}
```

Same adapter as `app_logs`, different source config (`otel_traces` table, its own field
mapping).

### Sentry errors — full

Only `mode: full` is implemented — Sentry's issue-search API is a flat list of issue
groups, not time-bucketed, so `summary`/`sample` aren't faked on top of it (see
`.plans/03-adapters.md`).

```json
POST /v1/query
{
  "sources": ["prod_errors"],
  "signal": "errors",
  "from": "now-24h", "to": "now",
  "filters": [
    {"field": "severity", "op": "eq", "value": "error"},
    {"field": "body", "op": "contains", "value": "timeout"}
  ],
  "mode": "full",
  "limit": 50
}
```

Native (`prod_errors`), the real org-scoped endpoint (live-verified 2026-09-06 —
the project-scoped one is deprecated):
```
GET /api/0/organizations/my-org/issues/?project=my-project&query=level:"error" "timeout"&start=...&end=...&limit=50
```

### VictoriaMetrics — structured and raw

```json
POST /v1/query
{
  "sources": ["prod_metrics"],
  "signal": "metrics",
  "from": "now-1h", "to": "now",
  "filters": [
    {"field": "name", "op": "eq", "value": "http_request_duration_seconds"},
    {"field": "labels.service", "op": "eq", "value": "checkout-api"}
  ],
  "mode": "full"
}
```

Native (`prod_metrics`):
```
GET /api/v1/query_range?query=http_request_duration_seconds{service="checkout-api"}&start=...&end=...&step=15s
```

Raw escape hatch:
```json
POST /v1/query
{
  "sources": ["prod_metrics"],
  "raw": "rate(http_requests_total{service=\"checkout-api\"}[5m])",
  "from": "now-1h", "to": "now"
}
```

### Cross-backend correlation

```json
POST /v1/context
{"trace_id": "4bf92f3577b34da6a3ce929d0e0e4736"}
```

Bundles, in one call: the `otel_traces` spans for that trace, the `app_logs` lines sharing
the trace ID, the `prod_errors` Sentry issue if the trace ID appears in an event's
contexts, and `prod_metrics` for `checkout-api` over the trace's window.
