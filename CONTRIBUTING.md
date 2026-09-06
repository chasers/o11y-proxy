# Contributing

See [`README.md`](README.md) for what this project is and how to run it, and
[`AGENTS.md`](AGENTS.md) for the working guide — architecture, the analysis tooling, and
the conventions the gates enforce.

## Dev setup

The toolchain is pinned in [`.tool-versions`](.tool-versions) and matched by
[`.github/workflows/ci.yml`](.github/workflows/ci.yml) — currently **OTP 27.3.4.16 /
Elixir 1.18.5**. With [mise](https://mise.jdx.dev) (or asdf):

```sh
mise install
mix deps.get
mix test          # everything that needs no live backend
```

Those versions are not free to bump: OTP must be one the Beam Machine CDN publishes a
precompiled ERTS for, or Burrito cannot build the single-file binaries. If you change
one of `.tool-versions`, `ci.yml`, or `release.yml`, change all three.

## Quality gate — run before opening a PR

```sh
mix ci         # compile -Werror, format check, credo --strict (ex_slop), audits, ex_dna, reach policy
mix dialyzer   # type analysis; its own CI job, and it needs a PLT built once
```

`mix precommit` is the mutating local variant — it formats and prunes rather than
telling you to — and it runs the tests. Use it while working; use `mix ci` before you
push, because that is what CI actually runs.

Backend suites are opt-in and CI does not run them, since they need live instances:

```sh
mix test --include sentry                                 # a real Sentry org (needs .env)
mix test --include clickhouse --include victoriametrics   # docker/docker-compose.yml
```

Run them locally against real backends before a release. "Green in CI" does not mean the
adapters work.

## Pull requests

1. Branch off `main`.
2. Keep each PR to one idea. If a change is big enough that reviewing it as one diff would
   be unpleasant, split it into a [stacked PR](https://docs.github.com/en/pull-requests/get-started/about-stacked-prs)
   chain with `gh stack` — each PR reviewable and mergeable on its own merit, bottom first.
3. Update `README.md` in the same change when behavior, commands, or structure move.
4. Get `mix ci`, `mix dialyzer` and the tests green locally.
5. Open the PR with a clear what and *why*. The why is the part that isn't in the diff.

If you touch the CLI or the distribution path, build the binary and try it — several
bugs there are invisible to `mix test` because they live in how a release boots
(`MIX_ENV=prod mix release`, then `burrito_out/`).

## Quality gates, and staying honest with them

CI gates against low-quality code, AI-generated or otherwise:

- `credo --strict` with the **ex_slop** plugin — LLM-pattern checks: blanket rescues,
  narrator comments, anti-idiomatic `Enum`, N+1.
- `ex_dna` — a duplication ratchet; new clones fail CI.
- `reach.check --arch` — the architecture policy in [`.reach.exs`](.reach.exs).
  `--smells --strict` fails on structural smells that are new relative to the committed
  baseline.

Don't disable a gate to get green; fix the code. When a check genuinely misfires, a
targeted `# credo:disable-for-next-line` with a reason is the honest response — a quiet
config edit is not.

Note that this project *does* use explanatory comments, unlike the template it was set up
from. The rule here is that a comment explains **why**, never what: why
`Application.start/2` is the CLI entry point, why a sentinel is `nil` rather than `0`.
`AGENTS.md` has the reasoning.
