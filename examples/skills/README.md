# Example agent skills

A [skill](https://docs.claude.com/en/docs/agents-and-tools/agent-skills) is a folder of
instructions an agent loads when a task matches its description. `o11y/` is a
ready-to-use one that teaches an agent to debug production with the `o11y-proxy` CLI —
the investigative loop, not just the flag list.

Copy it wherever your agent looks for skills. For Claude Code that is
`.claude/skills/` in a project, or `~/.claude/skills/` for every project:

```sh
mkdir -p ~/.claude/skills
cp -r examples/skills/o11y ~/.claude/skills/
```

It assumes `o11y-proxy` is on `PATH` and that a config exists (`./o11y.yaml`, or
`~/.config/o11y-proxy/config.yaml`, or wherever `O11Y_PROXY_CONFIG` points) — see the
[README](../../README.md). Nothing needs to be running: every command is one shot.

Edit it. The parts most worth making yours are the source names in the examples, and any
house rules about which windows are reasonable to query.
