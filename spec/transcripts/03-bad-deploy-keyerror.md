# Transcript: bad deploy introduces a KeyError

Errors-first investigation — starts at Sentry rather than logs or metrics. Walked against
the Phase 0 stub server.

**Prompt to agent:** "did the deploy 2 hours ago break checkout?"

---

**1. Sources** cached.

**2. Summary over the deploy window**

```json
POST /v1/query
{"sources": ["prod_errors"], "signal": "errors", "from": "now-6h", "to": "now",
 "filters": [{"field": "severity", "op": "eq", "value": "error"},
             {"field": "service", "op": "eq", "value": "checkout-api"}],
 "mode": "summary", "limit": 50}
```
→ 1, 2 errors/hour at baseline, then 164 and 201 in the two hours since the deploy.
`total_matched: 368`. Matches the reported deploy time closely enough to be worth chasing.

**3. Sample — what's actually failing?**

```json
{"sources": ["prod_errors"], "signal": "errors", "from": "now-2h", "to": "now",
 ...same filters, "mode": "sample", "limit": 20}
```
→ one issue dominating: `KeyError: key :discount_pct not found in %{code: "WELCOME10"}`,
`culprit: Checkout.Pricing.apply_discount/2`, `attributes.release:
checkout-api@2026.09.05-3` — the release that shipped 2 hours ago. Carries a `trace_id`
(Sentry surfaced it from the event's contexts, per `03-adapters.md`'s mapping note).

Note what's *absent* here: no stack trace in the sample. Per the token-budget rule in
`04-cross-cutting.md`, stack traces are large and excluded outside `mode: full` — this
sample was enough to identify the culprit function without paying for it.

**4. `/v1/context` on that trace**

```json
POST /v1/context
{"trace_id": "c3d4e5f6071829304a5b6c7d8e9f0a12"}
```
→ `trace`: single fast span (42ms) — the request fails *before* doing meaningful work, not
after a slow downstream call. Rules out the previous transcript's failure mode immediately.
`logs`: the same KeyError line, tagged with the new release.
`error`: full Sentry issue detail — 368 events, first seen 18:00:55, matching the release
rollout time.
`metrics`: `http_requests_errors_total` climbing 1 → 164 → 201 in step with the deploy.

**Conclusion:** the `checkout-api@2026.09.05-3` release has a bug in
`Checkout.Pricing.apply_discount/2` — it assumes every discount code carries a
`:discount_pct` key, and `WELCOME10` (and presumably other codes) doesn't. Every checkout
using that code path fails immediately. This is a rollback candidate, not a data or
infra issue.

## What this validates about the API

- Three different entry points across the three transcripts — logs, metrics, errors — all
  converge on the same `/v1/context` shape. An agent doesn't need to know in advance which
  signal will have the first clue; whichever one does, the next step is the same.
- The release tag flowing through in `attributes` (not a first-class canonical field) is
  the right call — it's backend-specific enough that promoting it to canonical would bloat
  the schema for every adapter that doesn't have a release concept, but common enough that
  losing it to a strict canonical/attributes split would hurt.
- This scenario didn't need `raw` at all — Sentry's `allow_raw: false` and the structured
  path was sufficient once `body`/`severity` filters were enough to isolate the one issue.
