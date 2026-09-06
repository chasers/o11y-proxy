o11y-proxy is an agent-friendly observability proxy: one interface — HTTP+JSON, or a
CLI — over Sentry, ClickHouse and VictoriaMetrics, so an agent can debug production
without learning three query dialects. `README.md` covers what it does and how to run it;
this file is about working *on* it.

The shape to keep in mind: everything under the transports (`Config`, `Query`, `Context`,
`Sources`, `Shaping`, `Response`, `ResponseError`) is transport-agnostic, and both the
HTTP router and the CLI enter it through the single façade `O11yProxy.Remote.handle/1`.
Adding a third transport should mean a third thin shell, never a second copy of the
dispatch. If you find yourself re-implementing an envelope, stop.

## Project guidelines

- Run `mix precommit` when you're done with a change and fix what it reports. It is
  *mutating* — it formats and prunes unused deps rather than complaining that you should
  have — and it compiles with warnings-as-errors, runs `credo --strict` with ex_slop,
  checks duplication with `ex_dna`, and runs the tests.
- `mix ci` is the non-mutating superset CI runs: the same checks in `--check` mode, plus
  `hex.audit`, `deps.audit`, and `reach.check --arch --smells`. It must pass before a PR
  is green. `mix dialyzer` runs as its own CI job.
- Architecture rules live in `.reach.exs`; a violation fails `mix ci`. Today there is one
  rule — no `String.to_atom` — and the reasoning is in the file. Add `layers:` and
  forbidden `deps:` there as boundaries appear.
- Use `Req` for HTTP. Every adapter already does; don't introduce a second client.
- **The pinned toolchain is load-bearing.** `.tool-versions`, `.github/workflows/ci.yml`
  and `.github/workflows/release.yml` must agree, and OTP must be a version the Beam
  Machine CDN publishes a precompiled ERTS for — Burrito cannot build a single-file binary
  otherwise. 27.3.4.17 exists upstream and 404s there, which is why we're on 27.3.4.16.
  Bumping any one of those three files alone breaks the release build, not CI, so the
  breakage shows up late.

## Understanding the codebase

Before reading files one by one, use the static-analysis tools — they answer structural
questions faster than grepping, and they catch patterns the compiler won't. All support
`--format json`.

- **Orient in an unfamiliar area** — `mix reach.map`: modules, coupling, `--hotspots`
  (highest-risk functions by branches × callers), `--boundaries`, `--effects`, `--depth`.
- **Before editing a function or module** — `mix reach.inspect <Mod.fun/arity | file:line>
  --impact --deps` shows the blast radius: callers, dependents, slices.
- **Trace data flow / taint** — `mix reach.trace --from params --to execute`, or
  `--backward file:line` / `--forward`. Useful for confirming a filter value really does
  reach a backend only as a bound parameter.
- **OTP topology** — `mix reach.otp --concurrency`: GenServer state machines, missing
  message handlers, supervision trees.
- **Dead code** — `mix reach.check --dead-code` (advisory, not a gate).
- **Duplication, before extracting a helper** — `mix ex_dna` lists clones;
  `mix ex_dna.explain <n>` shows the anti-unification and a suggested extraction.

## The gates, and how to stay honest with them

Don't disable a gate to get green — fix the code. Two of them have escape hatches that
are legitimate *when the finding is wrong*, and dishonest otherwise:

- `credo --strict` runs the **ex_slop** plugin: checks for LLM-ish patterns — blanket
  rescues, narrator comments, anti-idiomatic `Enum`, N+1. When a check genuinely
  misfires, `# credo:disable-for-next-line` with a one-line reason is correct; a silent
  config edit is not.
- `reach.check --smells --baseline .reach.baseline.json` fails only on *new* smells. The
  committed baseline currently holds six accepted findings, all of them "this map shape
  repeats" over the adapter contract's own return shapes (`%{records, native, total}`,
  `capabilities/1`'s map, `ResponseError`'s), plus one false positive claiming the
  backends should share a behaviour — they already declare `@behaviour O11yProxy.Backend`.
  Turning those into structs is a real design change, not a lint fix. If you accept a
  genuinely new smell, regenerate with
  `mix reach.check --arch --smells --write-baseline .reach.baseline.json`, and say why in
  the commit.

## Elixir guidelines

- **Comments explain *why*, never *what*.** This codebase deliberately carries a lot of
  them, and they are load-bearing: why `Application.start/2` is the CLI entry point, why
  the breaker's sentinel is `nil` and not `0`, why `:code.get_mode()` can't be used to
  detect a release. Every one of those encodes something that cost someone an afternoon.
  Delete a comment only when the code genuinely says the same thing. What ex_slop's
  narrator check is after is the other kind — `# increment the counter` above `count + 1`.
- No `String.to_atom/1` on anything a caller or a config file controls; the atom table is
  never garbage collected. `.reach.exs` enforces it. Keep dynamic identifiers as strings,
  or look them up against a known set (see `O11yProxy.Config.to_opts/2`).
- Tagged tuples for returns (`{:ok, _}` / `{:error, _}`), threaded with `with`/`case`.
- Every new module gets a mirrored test file (`lib/foo/bar.ex` → `test/foo/bar_test.exs`).
  Pure modules — `Query.Filter`, `ClickHouse.SQL`, `Sentry.Search`, `CLI.Args` — are pure
  so they can be tested exhaustively without booting anything. Preserve that seam.
- A new backend adapter passes `O11yProxy.BackendCase`, the shared contract suite. It is
  not optional, and it is where injection-safety is actually asserted.

## Tests

```sh
mix test                                                  # everything that needs no live backend
mix test --include sentry                                 # against a real Sentry org (needs .env)
mix test --include clickhouse --include victoriametrics   # against docker-compose
```

Backend-specific tags are excluded by default in `test/test_helper.exs` because they need
live instances and credentials. CI runs only the default set; the tagged suites are run
locally against real backends before a release.
