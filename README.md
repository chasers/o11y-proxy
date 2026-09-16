# o11y-proxy

**One way to query Sentry, ClickHouse, VictoriaMetrics, and logs sitting in S3.** Ask for
logs, metrics, traces, and errors in the same shape, and get answers back in the same
shape. You do not need to learn four query languages.

Built for AI agents debugging production, but it is a normal HTTP API and a normal CLI, so
it works fine for people too.

Two ways to use it:

- **CLI** — `o11y-proxy context --trace-id abc123`. Nothing to start.
- **HTTP** — run it as a server and `POST /v1/query`.

Both give you the same answer, byte for byte.

---

## Quick start

**1. Download the binary.** It includes its own Erlang. There is nothing else to install.

```bash
curl -LO https://github.com/chasers/o11y-proxy/releases/latest/download/o11y_proxy_macos_silicon
chmod +x o11y_proxy_macos_silicon
mv o11y_proxy_macos_silicon o11y-proxy
```

Also built for `linux_x86_64`, `linux_aarch64`, and `macos_x86_64`.

The first run unpacks the binary and takes a few seconds. Every run after that is fast.

**2. Write `o11y.yaml`.** Sentry is the easiest source to start with, because you do not
have to run anything locally.

```yaml
sources:
  - name: prod_errors
    backend: sentry
    signal: errors
    org: ${SENTRY_ORG}
    project: ${SENTRY_PROJECT}
    token: ${SENTRY_AUTH_TOKEN} # needs org:read
```

Secrets are always `${ENV_VAR}` references. The file never holds a real credential, so it
is safe to commit.

**3. Ask it something.**

```bash
export SENTRY_ORG=... SENTRY_PROJECT=... SENTRY_AUTH_TOKEN=...

o11y-proxy sources     # what is configured, and what each source can do
o11y-proxy health      # can it reach them?
o11y-proxy query --source prod_errors --signal errors \
  --from now-24h --to now --mode full --limit 5 | jq
```

That is the whole setup. No server to start.

---

## Commands

| Command | What it does |
|---|---|
| `o11y-proxy sources` | List sources and what each one supports |
| `o11y-proxy schema <source>` | Field names for one source, and example values |
| `o11y-proxy health` | Can each source be reached? |
| `o11y-proxy query …` | Query one source |
| `o11y-proxy context …` | Correlate one trace or error across **all** sources |
| `o11y-proxy serve` | Run the HTTP server |

`o11y-proxy` with no arguments runs the server. `o11y-proxy --help` lists every flag.

### `query`

Required: `--source`, `--signal`, `--from`, `--to`.

```bash
o11y-proxy query --source app_logs --signal logs --from now-1h --to now \
  --mode summary --filter severity=error
```

- `--signal` is `logs`, `metrics`, `traces`, or `errors`.
- `--mode` is `summary` (counts over time), `sample` (counts plus a few real records), or
  `full` (raw records). Default is `summary`.
- Times can be relative (`now-1h`) or RFC3339 (`2026-09-05T10:00:00Z`).

**Start with `summary`.** It returns counts, not thousands of log lines. Narrow the time
window and filters first, then switch to `sample` to see real records.

### `context`

This is the one that saves you the most work. Give it a trace ID and it returns the spans,
the log lines with that trace ID, the Sentry issue, and the metrics for that service — all
in one call, from every source at once.

```bash
o11y-proxy context --trace-id 4bf92f3577b34da6a3ce929d0e0e4736 | jq
```

No trace ID? Two other ways in:

```bash
o11y-proxy context --error-id 123456789          # start from a Sentry issue
o11y-proxy context --service checkout-api --from now-1h --to now
```

### Output

- Results are JSON on **stdout**. Notes and errors go to **stderr**, so `| jq` stays clean.
- Add `--pretty` if you are reading it yourself.
- **Exit 0** means you got an answer. This includes a partial answer, where one source
  failed and `errors[]` says which.
- **Exit 1** means the command, config, or connection was wrong.

---

## Filters

`--filter` can be repeated. Each operator has a short form:

| Write this | Means | Example |
|---|---|---|
| `field=v` | equals | `--filter severity=error` |
| `field!=v` | not equals | `--filter service!=cron` |
| `field>=v` | at least | `--filter attributes.duration_ms>=1000` |
| `field<=v` | at most | `--filter attributes.duration_ms<=50` |
| `field~v` | contains | `--filter body~timeout` |
| `field=~v` | regex | `--filter 'body=~^GET'` |
| `field?` | exists | `--filter trace_id?` |

Quote any filter your shell might try to read: `=~`, `>=`, `~`, `?`, and `!` are all
shell characters.

**Numbers stay numbers.** `duration_ms>=1000` sends the number `1000`, because backend
columns have types. To force a string, use double quotes: `--filter 'status="500"'`.

**`in` has no short form.** Splitting on commas would break values that contain commas.
Use `--raw` or the HTTP API instead.

---

## Reading a response

Every query response looks like this:

```json
{ "data": [...], "meta": {...}, "errors": [...] }
```

Three things worth knowing:

1. **`errors` is not failure.** If one source is down, you still get data from the others.
   Read both fields.
2. **`error: null` is different from an entry in `errors`.** `null` means "we asked, and
   there was nothing". An entry in `errors` means "that source broke".
3. **`meta.truncated`** means your filter is too wide, not that your limit is too small.

`meta.native_queries` shows the exact query sent to each backend. Read it. That is how you
learn a backend's own language well enough to use `--raw` later.

---

## Using it with an AI agent

[`examples/skills/o11y/`](examples/skills/o11y/) is a ready-made skill you can copy. It
teaches an agent how to investigate, not just which flags exist. See
[`examples/skills/README.md`](examples/skills/README.md) for where to put it.

---

## Running as a server

```bash
o11y-proxy serve      # 127.0.0.1:4000, loopback only
```

| Endpoint | Method |
|---|---|
| `/v1/query` | POST |
| `/v1/context` | POST |
| `/v1/sources` | GET |
| `/v1/sources/{name}/schema` | GET |
| `/healthz` | GET |
| `/metrics` | GET (Prometheus) |
| `/openapi.json` | GET (the full contract) |

```bash
curl -s localhost:4000/v1/context -H 'content-type: application/json' \
  -d '{"trace_id": "4bf92f3577b34da6a3ce929d0e0e4736"}' | jq
```

For a real service, use the release tarball instead of the binary. It has the standard
start scripts:

```bash
tar xzf o11y_proxy-0.3.0-linux-x86_64.tar.gz
./bin/o11y_proxy daemon      # or: start, start_iex
./bin/o11y_proxy rpc 'O11yProxy.Sources.list()'
./bin/o11y_proxy stop
```

Tarballs are published per platform (linux x86_64, linux aarch64, macOS silicon). The
single-file binaries are cross-compiled for all four targets.

<details>
<summary><b>The CLI uses a running server if it finds one (optional reading)</b></summary>

If a server is already running, the CLI calls it instead of doing the work itself. That
reuses the server's open connections. If no server is running, the CLI does the work
in-process and prints a note to stderr:

```
note: no daemon running (or its cookie doesn't match) — ran in-process in 0.2s.
      `o11y-proxy serve` in another terminal keeps connections warm.
```

The note only appears when stdout is a terminal. `--quiet` turns it off. Both paths give
identical output.

**How much does the server actually save?** Measured against a live Sentry source, 3-run
averages on one machine:

| Command | With a server | Without |
|---|---|---|
| `sources` (no network) | 181 ms | 185 ms |
| `health` (one round trip) | 930 ms | 1316 ms |
| `query` (one round trip) | 1735 ms | 1700 ms |

It saves connection setup and nothing else. The CLI is a new process either way, so it pays
the same ~180 ms of startup. Once a backend is across a network, the network dominates.
Useful, but not worth changing how you work.

**How it connects.** The server and the CLI form a two-node Erlang cluster on loopback:

- The server's node name comes from its port (`o11y_proxy_4000@127.0.0.1`). Two servers on
  different ports do not collide.
- The connection is **bound to 127.0.0.1**. It is never reachable from another machine.
- Access is controlled by the Erlang **cookie** in `releases/COOKIE`. **Treat that file as
  a credential.** Anyone who can read it and reach the port can run code on the node.
- Each build generates its own cookie. Artifacts from different builds cannot talk to each
  other, so the CLI just runs in-process instead. That is not an error.
- Connecting starts **epmd**, a small Erlang name server on `127.0.0.1:4369`. It keeps
  running after your command exits. That is normal, not a leak.

To turn all of this off, so every command runs in-process:

```yaml
server:
  distribution: false
```

</details>

---

## Config

o11y-proxy reads the first file it finds:

1. `./o11y.yaml`
2. `~/.config/o11y-proxy/config.yaml`
3. Wherever `O11Y_PROXY_CONFIG` points

It starts fine with no sources at all. The discovery endpoints work right away:

```bash
curl localhost:4000/healthz      # {"sources":{}}
curl localhost:4000/v1/sources   # {"sources":[]}
```

<details>
<summary><b>Logs in S3 (or GCS, or R2, or a directory)</b></summary>

The `s3` backend runs an embedded DuckDB over object storage, so a bucket of gzipped JSON
or Parquet answers `/v1/query` like anything else. `uri` takes any path DuckDB can read.

```yaml
sources:
  - name: log_archive
    backend: s3
    signal: logs
    uri: s3://acme-logs/cw/**/*.gz    # or gs://, r2://, https://, or ./some/dir
    format: json                      # json | parquet | csv
    region: us-east-1
    # Omit access_key_id/secret_access_key and DuckDB uses the AWS credential chain
    # (environment, shared config, instance/task role).
    mapping:
      timestamp: ts
      severity: level
      body: message
      service: service
      attributes: attrs
    hints:
      partition_key: ts
      hive_date_column: dt            # read this
      low_cardinality: [service]
```

**`hints.hive_date_column` is the one to get right.** Object storage bills per GET and per
byte scanned, so a query that cannot prune partitions is not slow, it is expensive. Given
it, the compiler bounds that column *inside the scan*, and a one-hour query opens one day's
objects instead of the bucket. Check `meta.native_queries` — the `WHERE CAST("dt" AS DATE)
BETWEEN` should be in the `scan` CTE.

If your records are nested rather than one-row-per-line — CloudWatch's are — add a
`transform`: a SELECT over the raw scan that flattens them into the columns `mapping`
names. [`examples/cloudwatch-s3/`](examples/cloudwatch-s3/) is a worked setup, log group to
query.

⚠️ **The macOS single-file binaries carry no `s3` backend.** The Linux binaries are fine.
On a Mac, run from source, or run the macOS tarball as a daemon and use HTTP — note that
the tarball gives you `bin/o11y_proxy daemon`, not the one-shot CLI. See
[Building the binaries](#developing) for why the artifacts differ.

</details>

<details>
<summary><b>ClickHouse, VictoriaMetrics and MinIO with docker-compose</b></summary>

```bash
docker compose -f docker/docker-compose.yml up -d
./docker/seed.sh && ./docker/seed-vm.sh && ./docker/seed-s3.sh
O11Y_PROXY_CONFIG=docker/o11y.yaml o11y-proxy serve
```

ClickHouse, VictoriaMetrics and Sentry have been verified against real backends:
ClickHouse 24.8, VictoriaMetrics v1.102.0, and a live Sentry org, with the full test suite
passing against all three at once.

Two caveats. The `docker/` compose file itself has not been run — the verification used the
same servers as standalone binaries, because this dev sandbox has no container runtime, and
`seed.sh`/`seed-vm.sh` did run unchanged against them. The MinIO service and `seed-s3.sh`
are new and in the same position. The `s3` adapter itself *is* covered by tests that run on
every CI build, against the Parquet fixture in `test/fixtures/s3/`.

</details>

---

## Status

**Working:** all four adapters, `/v1/query` (one source per call), `/v1/context` (fans out
to every source), circuit breakers, secret redaction, response size limits, and cursor
pagination.

**Not built yet:** a result cache, per-source rate limits, and the agent evaluation suite.

**Not started:** querying several sources in one `/v1/query` call. Use `/v1/context`, or
send one query per source.

Logflare/BigQuery support is deferred.

---

## Developing

Needs Erlang 27 and Elixir 1.18. Both are pinned in `.tool-versions`.

```bash
mise install          # or: asdf install
mix deps.get
mix run --no-halt     # serves on 127.0.0.1:4000
```

```bash
mix test              # everything that needs no live backend
mix precommit         # format, lint, test — run this before you push
mix ci                # what CI runs
```

Backend tests are opt-in, because they need live services:

```bash
mix test --include sentry
mix test --include clickhouse --include victoriametrics
mix test --include s3_minio    # needs docker compose up + ./docker/seed-s3.sh
```

The `s3` adapter is the exception: its contract suite runs on every `mix test`, against the
Parquet fixture in `test/fixtures/s3/`. DuckDB is embedded and Parquet is statically linked
into it, so there is nothing to stand up. `s3_minio` covers the rest — `httpfs`, secrets,
gzipped JSON.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full workflow and
[`AGENTS.md`](AGENTS.md) for the architecture and conventions.

<details>
<summary><b>Building the binaries</b></summary>

```bash
MIX_ENV=prod mix release --overwrite                                # all targets
BURRITO_TARGET=linux_aarch64 MIX_ENV=prod mix release --overwrite   # just one
```

Binaries go to `burrito_out/`. The tarball goes to `_build/prod/`. You need Zig (pinned in
`.tool-versions`) and `xz`. Windows targets need `7z` and are not built. To build only the
tarball — no Zig needed — set `O11Y_PROXY_SKIP_BURRITO=1`.

**The `s3` backend works everywhere except the macOS binaries.**

| artifact | `s3` backend | one-shot CLI | notes |
| --- | --- | --- | --- |
| `o11y_proxy_linux_{x86_64,aarch64}` | ✓ | ✓ | DuckDB cross-built against musl by `mix duckdb.stage` |
| `o11y_proxy_macos_*` | ✗ | ✓ | refuses an `s3` source at boot with a message saying this |
| `o11y_proxy-<version>-<platform>.tar.gz` | ✓ | ✗ | `start`/`daemon`/`rpc` only — see below |
| source install | ✓ | ✓ | |

**The tarball has no one-shot CLI**, which is easy to assume it does. `o11y-proxy sources`
works because the single-file binary passes your argv to the BEAM as plain arguments, which
`Application.start/2` intercepts before `Kernel.CLI` can (see `O11yProxy.CLI`'s moduledoc).
The standard release script has its own command list — `start`, `daemon`, `eval`, `rpc` —
and `./bin/o11y_proxy sources` just prints that list. Use `daemon` plus HTTP, or install
from source.

The one combination not available today is a Mac, a single binary, and `s3` together.

Burrito's ERTS is musl-linked and the NIF `adbc` ships is glibc-linked, so a binary cannot
load the stock one — `mix duckdb.stage` builds a musl one instead. It needs `cmake`, `zig`
and `patchelf`, runs automatically in the release workflow, and its moduledoc explains the
five pieces that have to line up. macOS would need a darwin-native build, which nothing
here does.

```sh
mix duckdb.stage                 # both Linux targets
mix duckdb.stage linux_aarch64   # just one
```

Intel macOS gets no published tarball either — GitHub retired the `macos-13` runners and a
tarball is native by construction. Build your own with `MIX_ENV=prod mix release`.

**Two traps that will cost you an afternoon:**

1. **Burrito installs by version.** It unpacks to
   `~/.local/share/.burrito/o11y_proxy_erts-<erts>_<version>/` and reuses that folder. If
   you rebuild without changing `version:` in `mix.exs`, you run the **old** code. Clear it
   with `./o11y_proxy_<target> maintenance uninstall`, or delete the folder.
2. **The Zig and OTP versions matter.** Burrito needs one exact Zig version — trust the
   error from `mix release`, not Burrito's README. OTP must be a version with a prebuilt
   ERTS on the Beam Machine CDN. Not every patch release is there: 27.3.4.17 exists but
   returns 404, which is why we pin 27.3.4.16.

Releases are automatic. Bump `version:` in `mix.exs`, merge to `main`, and CI builds the
binaries, tests them, and publishes the release.

</details>

---

## Example requests

<details>
<summary><b>ClickHouse logs — summary mode</b></summary>

The schema matches ClickStack's real `otel_logs` table, verified against
[ClickHouse's docs](https://clickhouse.com/docs/clickstack/ingesting-data/schemas#logs)
on 2026-09-06.

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

What actually runs:

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

</details>

<details>
<summary><b>ClickHouse traces — sample mode</b></summary>

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

Same adapter as `app_logs`. Only the source config differs: a different table and its own
field mapping.

</details>

<details>
<summary><b>Sentry errors — full mode only</b></summary>

Sentry only supports `mode: full`. Its issue search returns a flat list of issue groups,
not counts over time, so `summary` and `sample` are not faked on top of it.

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

What actually runs (the org-scoped endpoint, verified live on 2026-09-06 — the
project-scoped one is deprecated):

```
GET /api/0/organizations/my-org/issues/?project=my-project&query=level:"error" "timeout"&start=...&end=...&limit=50
```

</details>

<details>
<summary><b>VictoriaMetrics — structured and raw</b></summary>

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

What actually runs:

```
GET /api/v1/query_range?query=http_request_duration_seconds{service="checkout-api"}&start=...&end=...&step=15s
```

If the structured filters cannot express what you need, use `raw`. It is per-source, and
only allowed where the config sets `allow_raw: true`:

```json
POST /v1/query
{
  "sources": ["prod_metrics"],
  "raw": "rate(http_requests_total{service=\"checkout-api\"}[5m])",
  "from": "now-1h", "to": "now"
}
```

</details>

<details>
<summary><b>S3 — CloudWatch logs archived to a bucket</b></summary>

The source is the one in [`examples/cloudwatch-s3/o11y.yaml`](examples/cloudwatch-s3/o11y.yaml):
gzipped Firehose records under `cw/dt=…/hour=…/`, flattened by a `transform`.

```json
POST /v1/query
{
  "sources": ["cw_logs"],
  "signal": "logs",
  "from": "now-6h", "to": "now",
  "filters": [
    {"field": "service", "op": "eq", "value": "/aws/lambda/checkout-api"},
    {"field": "body", "op": "contains", "value": "connection refused"}
  ],
  "mode": "full",
  "limit": 20
}
```

What actually runs:

```sql
WITH scan AS (
  SELECT * FROM read_json('s3://acme-logs-archive/cw/**/*.gz',
                          format = 'newline_delimited',
                          hive_partitioning = true,
                          union_by_name = true)
  WHERE CAST("dt" AS DATE) BETWEEN ? AND ?
),
src AS (
  SELECT to_timestamp(e.timestamp / 1000) AS ts, logGroup AS service, e.message AS message,
         CASE WHEN regexp_matches(e.message, '(?i)\b(error|exception)\b') THEN 'error'
              ELSE 'info' END AS level,
         map {'log_stream': logStream, 'event_id': e.id, 'account': owner} AS attrs
  FROM scan, UNNEST(logEvents) AS u(e)
  WHERE messageType = 'DATA_MESSAGE'
)
SELECT "ts" AS timestamp, "level" AS severity, "message" AS body, "service" AS service,
       CAST(NULL AS VARCHAR) AS trace_id, CAST(NULL AS VARCHAR) AS span_id,
       "attrs" AS attributes
FROM src
WHERE "ts" BETWEEN ? AND ? AND "service" = ? AND contains(CAST("message" AS VARCHAR), ?)
ORDER BY "ts" DESC LIMIT 20
```

Two bounds, doing different jobs. The one in the `scan` CTE picks which **objects** to
open — that is the S3 bill. The one in the outer `WHERE` picks which **rows** to return,
because partitions are only day-granular and "the last six hours" is not "today".

Every `?` is a bound parameter. Filter values are never spliced into the SQL text, the same
guarantee the ClickHouse adapter gives.

</details>

<details>
<summary><b>Correlation across every backend</b></summary>

```json
POST /v1/context
{"trace_id": "4bf92f3577b34da6a3ce929d0e0e4736"}
```

One call returns:

- the `otel_traces` spans for that trace
- the `app_logs` lines with the same trace ID
- the `prod_errors` Sentry issue, if that trace ID appears in an event
- `prod_metrics` for `checkout-api` over the trace's own time window

Every source is queried at the same time under one deadline. A slow or broken backend
becomes an entry in `errors` while the healthy ones still return data.

Metrics are the interesting part. They carry no trace ID, so the lookup runs in two steps:
fan out the trace ID first, then use the service and time window *found* in those results
to query the metrics sources.

Two other ways in, when you have no trace ID:

```json
POST /v1/context
{"error_id": "123456789"}

POST /v1/context
{"from": "now-1h", "to": "now", "service": "checkout-api"}
```

</details>
