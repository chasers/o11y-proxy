# Transcript: slow downstream payment gateway

Metrics-first investigation — the case where the agent is expected to reach for `raw`
MetricsQL rather than structured filters. Walked against the Phase 0 stub server.

**Prompt to agent:** "p99 latency on checkout looks bad today, what's going on?"

---

**1. Sources** already cached from an earlier call this session.

**2. Raw MetricsQL — the natural interface for metrics**

```json
POST /v1/query
{"sources": ["prod_metrics"], "signal": "metrics",
 "raw": "histogram_quantile(0.99, rate(http_request_duration_seconds_bucket{service=\"checkout-api\"}[5m]))",
 "from": "now-3h", "to": "now"}
```
→ `http_request_duration_seconds:p99{service="checkout-api", route="/checkout"}`:
`0.31 → 0.34 → 2.87 → 3.12` (seconds) across the last three hours. Roughly 9x step change
between the 2nd and 3rd points, not a gradual drift.

**3. Cross-check with traces, summary mode**

```json
{"sources": ["otel_traces"], "signal": "traces", "from": "now-3h", "to": "now",
 "filters": [{"field": "service", "op": "eq", "value": "checkout-api"},
             {"field": "attributes.duration_ms", "op": "gte", "value": 1000}],
 "mode": "summary", "limit": 50}
```
→ slow-span (≥1000ms) counts: 4, 6, then 211 in the current hour. Same step change the
metric showed, now localized to a bucket.

**4. Sample the slow spans**

```json
{"sources": ["otel_traces"], "signal": "traces", "from": "now-15m", "to": "now",
 ...same filters, "mode": "sample", "limit": 20}
```
→ representative span: `POST /checkout`, `duration_ms: 3120`, carries `trace_id`.

**5. `/v1/context` on that trace**

```json
POST /v1/context
{"trace_id": "b2c3d4e5f60718293a4b5c6d7e8f9001"}
```
→ `trace`: root span 3120ms, child span `POST https://api.payment-gateway.example/v1/charges`
at 3081ms — essentially the entire request latency is this one downstream call.
`logs`: a `warn` line the app itself logged: `"payment-gateway responded in 3081ms (p99
budget 500ms)"` — the app already suspected this.
`error`: **none** — no Sentry issue exists for this trace, and the envelope says so
explicitly (`errors: [{"source": "prod_errors", "code": "invalid_query", "message": "no
matching issue for this trace_id"}]`) rather than silently omitting the field. This is not
a failure of the investigation — slow-but-successful requests don't raise exceptions, so
no issue is the *correct* answer, and the agent can tell the difference between "no error
exists" and "the error source failed to respond."
`metrics`: same p99 series, scoped to the surrounding window.

**Conclusion:** latency is not in checkout-api's own code — it's fully attributable to the
`payment-gateway` peer call, which regressed from ~150ms to ~3s. Next step is on the
gateway side, not this service.

## What this validates about the API

- Confirms `03-adapters.md`'s prediction: the agent reached for `raw` MetricsQL on the very
  first metrics call rather than the structured filter form. The structured path exists for
  consistency and simple cases, not because it's what an agent will prefer here.
- `errors` as a peer of `data` — populated with a real, distinguishable code — is what lets
  "no Sentry issue" and "Sentry timed out" mean different things. If `error: null` were the
  only signal, those two cases would be indistinguishable and the agent might wrongly
  conclude the error source is broken.
- Attribute name `peer.service` on the client span is what let `/v1/context`'s bundle make
  the downstream-attribution call in one read, without a second query.
