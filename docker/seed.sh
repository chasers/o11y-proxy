#!/usr/bin/env bash
# Creates otel_test.otel_logs / otel_test.otel_traces and seeds a handful of rows
# anchored on "now" so the ClickHouse BackendCase test
# (test/o11y_proxy/backends/click_house_test.exs, `mix test --include clickhouse`) finds
# them inside its +/-1h window. Requires `docker compose up -d` first (see
# docker-compose.yml).
#
# otel_logs matches ClickStack's real schema (verified against
# https://clickhouse.com/docs/clickstack/ingesting-data/schemas#logs, 2026-09-06) —
# table name and all seven core columns below line up exactly. ClickStack's actual table
# also carries ResourceAttributes/ScopeAttributes/ScopeName/etc.; omitted here since this
# adapter's `attributes` mapping targets one map column (log-record-level LogAttributes),
# not resource/scope-level metadata.
set -euo pipefail

CH_URL="${CH_URL:-http://localhost:8123}"

curl -sf "$CH_URL/?database=otel_test" --data-binary @- <<'SQL'
CREATE TABLE IF NOT EXISTS otel_logs
(
    Timestamp      DateTime64(9),
    TraceId        String,
    SpanId         String,
    SeverityText   String,
    SeverityNumber UInt8,
    ServiceName    String,
    Body           String,
    LogAttributes  Map(String, String)
)
ENGINE = MergeTree
ORDER BY (ServiceName, Timestamp)
SQL

curl -sf "$CH_URL/?database=otel_test" --data-binary @- <<'SQL'
CREATE TABLE IF NOT EXISTS otel_traces
(
    Timestamp      DateTime64(9),
    TraceId        String,
    SpanId         String,
    ParentSpanId   String,
    SpanName       String,
    ServiceName    String,
    Duration       Int64,
    StatusCode     String, -- "Ok" | "Error" | "Unset" — mapped onto canonical `severity`
    SpanAttributes Map(String, String)
)
ENGINE = MergeTree
ORDER BY (ServiceName, Timestamp)
SQL

ts() { date -u -d "@$(( $(date +%s) - $1 ))" +"%Y-%m-%d %H:%M:%S.000000000"; }

curl -sf "$CH_URL/?database=otel_test&query=INSERT+INTO+otel_logs+FORMAT+JSONEachRow" --data-binary @- <<JSON
{"Timestamp": "$(ts 60)", "TraceId": "a1b2c3d4e5f60708192a3b4c5d6e7f80", "SpanId": "a3b4c5d6e7f80102", "SeverityText": "ERROR", "SeverityNumber": 17, "ServiceName": "checkout-api", "Body": "connection pool timeout: could not obtain connection from payments-db pool within 5000ms", "LogAttributes": {"db_pool": "payments-db"}}
{"Timestamp": "$(ts 120)", "TraceId": "b2c3d4e5f60718293a4b5c6d7e8f9001", "SpanId": "b2c3d4e5f6070001", "SeverityText": "WARN", "SeverityNumber": 13, "ServiceName": "checkout-api", "Body": "payment-gateway responded in 3081ms (p99 budget 500ms)", "LogAttributes": {"peer_service": "payment-gateway"}}
{"Timestamp": "$(ts 5)", "TraceId": "c3d4e5f6071829304a5b6c7d8e9f0a12", "SpanId": "c3d4e5f607180000", "SeverityText": "INFO", "SeverityNumber": 9, "ServiceName": "checkout-api", "Body": "POST /checkout 200 OK", "LogAttributes": {}}
JSON

curl -sf "$CH_URL/?database=otel_test&query=INSERT+INTO+otel_traces+FORMAT+JSONEachRow" --data-binary @- <<JSON
{"Timestamp": "$(ts 60)", "TraceId": "a1b2c3d4e5f60708192a3b4c5d6e7f80", "SpanId": "a3b4c5d6e7f80102", "ParentSpanId": "a3b4c5d6e7f80100", "SpanName": "db.connection.acquire payments-db", "ServiceName": "checkout-api", "Duration": 5000000000, "StatusCode": "Error", "SpanAttributes": {"db_pool": "payments-db"}}
{"Timestamp": "$(ts 120)", "TraceId": "b2c3d4e5f60718293a4b5c6d7e8f9001", "SpanId": "b2c3d4e5f6070001", "ParentSpanId": "b2c3d4e5f6070000", "SpanName": "POST https://api.payment-gateway.example/v1/charges", "ServiceName": "checkout-api", "Duration": 3081000000, "StatusCode": "Ok", "SpanAttributes": {"peer_service": "payment-gateway"}}
{"Timestamp": "$(ts 5)", "TraceId": "c3d4e5f6071829304a5b6c7d8e9f0a12", "SpanId": "c3d4e5f607180000", "ParentSpanId": "", "SpanName": "POST /checkout", "ServiceName": "checkout-api", "Duration": 42000000, "StatusCode": "Ok", "SpanAttributes": {}}
JSON

echo "Seeded otel_test.otel_logs and otel_test.otel_traces at $CH_URL"
