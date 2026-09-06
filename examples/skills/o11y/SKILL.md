---
name: o11y
description: Debug production issues (errors, latency, log spikes) with the o11y-proxy CLI — one command-line interface over logs, metrics, traces, and error tracking. Use when investigating an incident, a spike in errors, a latency regression, or when correlating a trace or error across backends. Do not use for local development debugging or reading source code.
---

# o11y-proxy debugging loop

`o11y-proxy` is one command in front of every observability backend (ClickHouse-backed
logs and traces, VictoriaMetrics, Sentry). It exists so you don't need to learn each
backend's query dialect to debug production — but its bigger job is protecting your
context window. A naive investigation pulls thousands of raw log lines; this tool is built
to get you to a root cause in a handful of small, aggregated calls instead.

There is nothing to start and no port to check. Every command is one shot: it answers and
exits. If a daemon happens to be running it will use it, and if not it does the work
itself — either way you get the same answer, so never make starting one a step.

Output is JSON on stdout and diagnostics on stderr, so `| jq` is always safe. Exit status
is 0 whenever an answer was produced — **including a partial one** — and 1 only for a bad
command, a config problem, or an unknown source.

## The loop

1. **`o11y-proxy sources`** — what backends and sources exist. Read this once and remember
   it; it rarely changes. Each source lists `capabilities`: which signals it serves, which
   operators it can express, which modes it supports, whether `--raw` is allowed. Check it
   before assuming a mode or operator exists — Sentry sources, for instance, only support
   `--mode full`, because its issue search is a flat list and not time-bucketed.

2. **`--mode summary`, over a wide window.** Where and when is the problem? Summary returns
   time-bucketed counts, never raw records. This is almost always the right first call,
   whether you're chasing errors, latency, or a log spike. Look for a step change, not just
   a high number.

   ```sh
   o11y-proxy query --source app_logs --signal logs --from now-24h --to now \
     --mode summary --filter severity=error | jq '.data'
   ```

3. **Narrow the window and the filters. Still `summary`.** Confirm the anomaly is localized
   and no longer moving before you spend a call on individual records.

4. **`--mode sample`.** What do these actually look like? Sample returns a handful of
   representative records spread across the window — not just the most recent N — plus the
   summary. This is usually where you find a `trace_id` to pull on.

   ```sh
   o11y-proxy query --source app_logs --signal logs --from now-1h --to now \
     --mode sample --filter severity=error --filter service=checkout-api \
     | jq '.data[] | {timestamp, body, trace_id}'
   ```

5. **Pull the thread: `o11y-proxy context --trace-id <id>`.** This is the command that
   makes the tool worth using over querying each backend yourself. One call returns the
   trace's spans, every log line sharing that trace ID across every logs source, the Sentry
   issue if there is one, and metrics for the owning service over the same window — the
   whole story instead of four separate lookups.

   No trace ID yet? `--error-id <id>` starts from a Sentry issue and correlates on the
   trace ID it carries; `--service <name> --from <when> --to <when>` correlates a service
   over a window with no anchor entity at all.

6. **`--mode full` only if you still need raw lines**, and only with tight filters. This is
   the expensive mode: cursor-paginated raw records, no aggregation. Continue a page with
   `--cursor "$(… | jq -r .meta.cursor)"`.

**The anti-pattern, named explicitly: do not open with `--mode full --limit 1000` over a
24-hour window.** That burns your context on a wall of undifferentiated log lines before
you have even confirmed where or when the problem is. Every step above exists to make that
unnecessary.

## Filters

`--filter` repeats, and takes one compact form per operator:

| Form | Means | Example |
|---|---|---|
| `field=v` | equals | `--filter severity=error` |
| `field!=v` | not equals | `--filter service!=cron` |
| `field>=v` | at least | `--filter attributes.duration_ms>=1000` |
| `field<=v` | at most | `--filter attributes.duration_ms<=50` |
| `field~v` | contains | `--filter body~timeout` |
| `field=~v` | regex | `--filter 'body=~^GET /api'` |
| `field?` | exists | `--filter trace_id?` |

Quote any filter containing shell metacharacters — `=~`, `>=`, `~`, `?` and `!` are all
things a shell may try to interpret. Numeric- and boolean-looking values are sent as
numbers and booleans, because the backends' columns have types; wrap a value in double
quotes to force a string: `--filter 'status="500"'`.

There is no compact form for `in` — comma-splitting would be ambiguous against values that
contain commas. Use `--raw`, where the source allows it.

## Reading responses

A query response is `{"data": [...], "meta": {...}, "errors": [...]}`.

**`errors` being non-empty does not mean the call failed.** A fan-out returns whatever
succeeded in `data` and a structured entry per failed source in `errors`, and still exits
0. Read both. Equally, an absent value — `"error": null` in a context bundle — means
"queried, nothing matched", which is *different* from that source appearing in `errors`
("the source itself failed"). Don't conflate them.

Check `meta.truncated` and `meta.total_matched`. If truncated, your filter is too wide —
not your limit too small.

`meta.native_queries` shows the exact query that ran against each backend. Read it. It is
how you learn a backend's dialect well enough to reach for `--raw` later, from a real
working example rather than a guess:

```sh
o11y-proxy query --source app_logs --signal logs --from now-1h --to now \
  --filter severity=error | jq -r '.meta.native_queries'
```

`o11y-proxy schema <source>` lists a source's fields — each with its `canonical` name, the
`native` column or parameter behind it, whether it is `filterable`, and `sample_values`
for low-cardinality ones. Consult it when a filter comes back with an unknown-field error,
or to discover what a field can actually contain:

```sh
o11y-proxy schema app_logs | jq -r '.fields[] | select(.filterable) | .canonical'
```

## When something looks wrong

- **`no such source`** — run `o11y-proxy sources`; the name is the configured source name,
  not the backend type.
- **An `unreachable` entry in `errors` with `retry_after_ms`** — that source's circuit
  breaker is open after repeated failures. Other sources still answered; work with what
  came back rather than retrying immediately.
- **A note on stderr about running in-process** — informational, not an error. The answer
  on stdout is complete. Pass `--quiet` if it is in your way.
- **`o11y-proxy --help`** — the full flag surface, always current with the binary you have.
