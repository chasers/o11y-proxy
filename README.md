# o11y-proxy

An agent-friendly observability proxy in Elixir. One HTTP+JSON interface over Sentry,
ClickHouse, and VictoriaMetrics (Logflare/BigQuery deferred), so an agent can debug
production without learning three query dialects.

Status: ClickHouse, VictoriaMetrics, and Sentry adapters implemented and passing their
contract tests, plus cross-backend correlation — `/v1/query` (single source) and
`/v1/context` (fan-out across every configured source) are both live, with circuit
breakers, attribute redaction, response byte ceilings, and cursor pagination (Phases 0-5,
see `.plans/05-roadmap.md`). Not built yet: the result cache, per-source rate limiting,
and the agent eval suite.

## Install

Published releases carry two kinds of artifact — pick by how you intend to run it.

**Single-file binary** (nothing to install, no Erlang required — it bundles its own):

```bash
curl -LO https://github.com/chasers/o11y-proxy/releases/latest/download/o11y_proxy_macos_silicon
chmod +x o11y_proxy_macos_silicon
./o11y_proxy_macos_silicon      # reads ./o11y.yaml
```

Built for `linux_x86_64`, `linux_aarch64`, `macos_silicon` and `macos_x86_64`. First run
unpacks itself to `~/.local/share/.burrito/` and takes a few seconds; later runs are fast.

**OTP release tarball** (`o11y_proxy-<version>-linux-x86_64.tar.gz`) — for running it as a
real service. Also bundles its own Erlang, and keeps the standard release script:

```bash
tar xzf o11y_proxy-0.1.0-linux-x86_64.tar.gz
./bin/o11y_proxy daemon                      # or: start, start_iex
./bin/o11y_proxy rpc 'O11yProxy.Sources.list()'
./bin/o11y_proxy stop
```

The binary is the better first-run experience; the tarball is what you want under systemd,
since `daemon`/`stop`/`remote`/`rpc` come with it. Note the tarball is built for the
platform it was released from (linux x86_64), while the binaries are cross-compiled.

## Quickstart (from source)

Needs Erlang 27 and Elixir 1.18 — both pinned in `.tool-versions`, so with
[mise](https://mise.jdx.dev) (or asdf) installed:

```bash
mise install          # or: asdf install
mix deps.get
mix run --no-halt     # serves on 127.0.0.1:4000, loopback only
```

It boots with zero sources configured, which is a useful state — the discovery endpoints
work immediately:

```bash
curl localhost:4000/healthz      # {"sources":{}}
curl localhost:4000/v1/sources   # {"sources":[]}
curl localhost:4000/openapi.json # the full API contract
```

### Point it at something real

Sources live in `o11y.yaml` (or `~/.config/o11y-proxy/config.yaml`, or wherever
`O11Y_PROXY_CONFIG` points). Secrets are `${ENV_VAR}` references only — the file never
holds a credential, so it stays safe to commit. A Sentry source needs the least setup,
since there's nothing to run locally:

```yaml
sources:
  - name: prod_errors
    backend: sentry
    signal: errors
    org: ${SENTRY_ORG}
    project: ${SENTRY_PROJECT}
    token: ${SENTRY_AUTH_TOKEN} # needs org:read — see .plans/03-adapters.md
```

```bash
cp .env.sample .env    # fill in SENTRY_AUTH_TOKEN / SENTRY_ORG / SENTRY_PROJECT
set -a; source .env; set +a
mix run --no-halt
```

For ClickHouse and VictoriaMetrics there's a docker-compose stack with seed data:

```bash
docker compose -f docker/docker-compose.yml up -d
./docker/seed.sh && ./docker/seed-vm.sh
O11Y_PROXY_CONFIG=docker/o11y.yaml mix run --no-halt
```

All three adapters have now been verified against real backends — ClickHouse 24.8 and
VictoriaMetrics v1.102.0 (the versions this compose file pins) and a live Sentry org,
with the full suite green against all three at once. The `docker/` compose file itself is
the one piece still unexercised: the verification ran the same two servers as standalone
binaries, since this repo's dev sandbox has no container runtime. `seed.sh` and
`seed-vm.sh` did run unmodified against them.

### First calls

```bash
# What exists, and what each source can actually do
curl localhost:4000/v1/sources | jq

# Query one source. Sentry only supports mode: full (its issue search is a flat list,
# not time-bucketed); ClickHouse sources also take "summary" and "sample".
curl -s localhost:4000/v1/query -H 'content-type: application/json' -d '{
  "sources": ["prod_errors"], "signal": "errors",
  "from": "now-24h", "to": "now", "mode": "full", "limit": 5
}' | jq '.data[].body, .meta.native_queries'

# Then correlate — one call instead of six
curl -s localhost:4000/v1/context -H 'content-type: application/json' \
  -d '{"trace_id": "4bf92f3577b34da6a3ce929d0e0e4736"}' | jq
```

`meta.native_queries` in every response shows the exact query that ran against each
backend, which is how you learn a dialect well enough to reach for `raw` later.

### Tests

```bash
mix test                                    # everything that needs no live backend
mix test --include sentry                   # against a real Sentry org (needs .env)
mix test --include clickhouse --include victoriametrics   # against docker-compose
```

### Building the distributables

```bash
MIX_ENV=prod mix release --overwrite                     # all targets + the tarball
BURRITO_TARGET=linux_aarch64 MIX_ENV=prod mix release --overwrite   # just one
```

Binaries land in `burrito_out/`, the tarball in `_build/prod/`. Needs Zig (pinned in
`.tool-versions`) and `xz`; Windows targets would additionally need `7z` and aren't built.

Two things that will otherwise cost you an afternoon:

- **Burrito installs by version.** It unpacks to
  `~/.local/share/.burrito/o11y_proxy_erts-<erts>_<version>/` and reuses that directory,
  so rebuilding without bumping `version:` in `mix.exs` runs the *old* code. Clear it with
  `./o11y_proxy_<target> maintenance uninstall`, or `rm -rf` the directory.
- **Zig and OTP versions are load-bearing.** Burrito demands one exact Zig version (its
  README has lagged behind the code — trust the error from `mix release`), and OTP must be
  a version the Beam Machine CDN publishes a precompiled ERTS for. Not every patch release
  is there: 27.3.4.17 exists upstream but 404s, which is why `.tool-versions` pins
  27.3.4.16.

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

Every source is queried concurrently under one deadline, so a slow or broken backend
becomes an entry in `errors` while the healthy ones still return data. `error: null` means
"queried, no matching issue" — distinct from an entry in `errors`, which means the error
source itself failed.

Two other ways in, when you don't have a trace ID:

```json
POST /v1/context
{"error_id": "7627311504"}                                  // resolves the error, then
                                                            // correlates on its trace ID
{"from": "now-1h", "to": "now", "service": "checkout-api"}   // no anchor entity
```

Metrics are the interesting case: they carry no `trace_id`, so a trace lookup runs in two
stages — fan out the trace ID first, then use the service and time window *discovered*
from those results to query the metrics sources.
