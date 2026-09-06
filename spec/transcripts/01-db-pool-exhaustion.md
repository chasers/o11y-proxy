# Transcript: DB connection pool exhaustion

Logs-first investigation. Walked against the Phase 0 stub server (`stub/server.js`).

**Prompt to agent:** "checkout-api is erroring a lot in the last hour, figure out why."

---

**1. Discover sources** (cached for the session — this rarely changes)

```
GET /v1/sources
```
→ `app_logs` (clickhouse/logs), `otel_traces` (clickhouse/traces), `prod_errors`
(sentry/errors), `prod_metrics` (victoriametrics/metrics).

**2. Wide summary — where and when?**

```json
POST /v1/query
{"sources": ["app_logs"], "signal": "logs", "from": "now-1h", "to": "now",
 "filters": [{"field": "severity", "op": "gte", "value": "error"},
             {"field": "service", "op": "eq", "value": "checkout-api"}],
 "mode": "summary", "limit": 50}
```
→ error counts flat at 2-4/bucket until `19:45`, then jump to 187, then 142.
`total_matched: 338`. Clear step change 15 minutes ago, not a gradual climb.

**3. Narrow the window, still summary**

```json
{"from": "now-20m", "to": "now-5m", ...same filters, "mode": "summary"}
```
→ confirms the spike is concentrated in this 15-minute window (187 then 94 falling off),
not still climbing. `total_matched: 281`.

**4. Sample — what do these actually look like?**

```json
{"from": "now-20m", "to": "now-5m", ...same filters, "mode": "sample", "limit": 20}
```
→ two representative lines, same message:
`"connection pool timeout: could not obtain connection from payments-db pool within 5000ms"`,
`attributes: {db_pool: "payments-db", pool_size: 20, pool_in_use: 20}`. Each carries a
`trace_id`.

**5. Pull the thread — `/v1/context`**

```json
POST /v1/context
{"trace_id": "a1b2c3d4e5f60708192a3b4c5d6e7f80"}
```
→ one call, four sources:
- `trace`: root span `POST /checkout` (5012ms) → child span `db.connection.acquire
  payments-db` (5000ms, exactly the pool timeout).
- `logs`: the same pool-timeout line, correlated by trace ID.
- `error`: Sentry issue `PoolTimeoutError: payments-db`, 331 events, first seen 19:44:50 —
  matches the log spike almost to the second.
- `metrics`: `db_pool_in_use{service="checkout-api", pool="payments-db"}` climbing
  12 → 18 → 20 → 20 over the same window. Pinned at the pool ceiling.

**Conclusion:** `payments-db` connection pool (size 20) saturated around 19:44 and stayed
pinned; every checkout request blocked 5s waiting for a connection, then failed. Root cause
is upstream of the code — either a leak holding connections open, a traffic spike, or the
pool size needs raising — but the *what* and *when* took two summary calls, one sample,
and one context call. No `mode: full` needed.

## What this validates about the API

- `summary` → `summary` (narrower) → `sample` → `context` reached a root cause in 4 calls
  without ever asking for raw records.
- `native_queries` in every response would let a human (or the agent, next time) skip
  straight to raw SQL/API calls if this shape recurs.
- The four-way fan-out in `/v1/context` — trace spans, logs, Sentry issue, and the *metric
  that explains the mechanism* (pool utilization) — is what made this one call instead of
  four separate ones plus manual trace_id copy-pasting.
