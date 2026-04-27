---
tags: [claude-code, anthropic, agent, cli, skills, hooks, settings]
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://code.claude.com/docs/en/overview
  - https://code.claude.com/docs/en/cli-reference
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Claude Code — CLI + skills + hooks

@trace spec:agent-cheatsheets

## Provenance

- Claude Code official docs — overview (install, surfaces, CLAUDE.md, skills, hooks — the canonical Anthropic reference): <https://code.claude.com/docs/en/overview>
- Claude Code CLI reference (flags `--model`, `--resume`, `--version`): <https://code.claude.com/docs/en/cli-reference>
- **Last updated:** 2026-04-25

**Version baseline**: `@anthropic-ai/claude-code` baked at `/opt/agents/claude/` (linked into PATH as `claude`)
**Use when**: launching Claude Code from inside the forge, configuring skills/hooks, debugging session state.

## Quick reference

| Command | Effect |
|---|---|
| `claude` | start an interactive session in the current directory |
| `claude --version` | show the bundled CLI version |
| `claude --model <id>` | override the default model for this session |
| `claude --resume <id>` | resume a previous session by ID |

| Path | Purpose |
|---|---|
| `~/.claude/CLAUDE.md` | host-wide instructions (currently kept empty per host-portability convention) |
| `<project>/CLAUDE.md` | project-specific instructions (auto-loaded when CWD is in the project tree) |
| `~/.claude/settings.json` | hook config, permission allowlists, env vars |
| `<project>/.claude/settings.json` | project-scoped overrides (hooks, allowlists) |
| `~/.claude/projects/<encoded-cwd>/memory/MEMORY.md` | auto-memory index; loaded into every session in that project |

## Common patterns

### Pattern 1 — launch with explicit model

```bash
claude --model claude-opus-4-7
claude --model claude-sonnet-4-6
claude --model claude-haiku-4-5
```

Default model per session is whatever `~/.claude/settings.json` specifies. Override per session with `--model`.

### Pattern 2 — read the project's CLAUDE.md before starting work

```bash
cat ./CLAUDE.md           # project-local conventions (build, test, OpenSpec rules, etc.)
ls .claude/settings.json  # project-scoped hooks/allowlists if any
```

CLAUDE.md is the project's contract with the agent. Read it first.

### Pattern 3 — use the auto-memory system

Memory entries live in `~/.claude/projects/<encoded-cwd>/memory/MEMORY.md` plus per-topic markdown files. Each entry has frontmatter:

```markdown
---
name: <short title>
description: <one-line description>
type: user | feedback | project | reference
---

<body>
```

`MEMORY.md` is an index — keep it ≤ 200 lines because lines after that get truncated. Put content in dedicated files, link from the index.

### Pattern 4 — invoke a skill (slash command)

In a session: `/skill-name [args]`. From the CLI side, skills are configured globally or per-project in `settings.json`. The session lists available skills in `<system-reminder>` blocks at startup.

### Pattern 5 — configure hooks via settings.json

```json
{
  "hooks": {
    "user-prompt-submit-hook": "echo 'prompt received' >> ~/log",
    "tool-use-hook": "..."
  },
  "permissions": {
    "allow": ["Bash(npm test*)", "Read(./src/**)"]
  }
}
```

Hooks are shell commands the harness runs around prompts/tool calls. Permissions allowlist tools so they don't prompt the user.

## Common pitfalls

- **Editing CLAUDE.md mid-session** — the file is read at session start. Mid-session edits don't affect the current session; restart for changes to apply.
- **Skipping the project CLAUDE.md** — the agent rule of thumb is "read CLAUDE.md before any non-trivial action". Skipping it means walking past hard requirements like "all changes go through OpenSpec".
- **Putting workflow rules in `~/.claude/CLAUDE.md`** — that file is host-local and gets wiped if the host is wiped. Workflow lives in project CLAUDE.md (checked into git). The host file is just an index.
- **Using `--model` with a deprecated model ID** — Claude Code rejects retired model IDs. The current Claude family is 4.x: `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5`. Knowledge cutoff for the assistant is January 2026.
- **Misunderstanding the difference between user-invocable skills and auto-loaded skills** — user-invocable skills appear in the slash-command list. Auto-loaded skills run on triggers (e.g., file-extension match). Both are configured via the agent SDK / settings.
- **Trying to run Claude Code from a non-project directory** — many features (CLAUDE.md, project memory, project-scoped hooks) need the CWD to be inside a project tree. `cd $HOME/src/<project>` before launching.
- **Forgetting to commit `.claude/settings.json` changes** — project-scoped settings only take effect when the file is checked in. Local-only edits silently apply to your machine but not to other contributors.

## Telemetry obligations — cheatsheet-telemetry

@trace spec:cheatsheets-license-tiered

Every cheatsheet consultation by Claude Code SHOULD emit one JSONL line to
`/var/log/tillandsias/external/cheatsheet-telemetry/lookups.jsonl`. Schema
+ examples in `runtime/external-logs.md` ("Producer: cheatsheet-telemetry").
Path is RW for forge containers; append-only; auditor caps at 10 MB rotate.

The load-bearing event is `resolved_via: miss` — emit it whenever you read
a cheatsheet but had to pull deeper context (live-api, pull-on-demand
recipe, web search). Misses tell the host which cheatsheets need refresh.

```bash
jq -cn --arg ts "$(date -u -Iseconds)" --arg cs "languages/python.md" \
       --arg q "asyncio cancellation" --arg via "miss" \
  '{ts: $ts, project: $TILLANDSIAS_PROJECT, cheatsheet: $cs, query: $q,
    resolved_via: $via, pulled_url: null, chars_consumed: 0,
    spec: "cheatsheets-license-tiered", accountability: true}' \
  >> /var/log/tillandsias/external/cheatsheet-telemetry/lookups.jsonl
```

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream license redistribution status not granted (or off-allowlist).
> See `cheatsheets/license-allowlist.toml` for the per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

<!-- TODO: hand-curate the recipe before next forge build -->

### Source

- **Upstream URL(s):**
  - `https://code.claude.com/docs/en/overview`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/code.claude.com/docs/en/overview`
- **License:** see-license-allowlist
- **License URL:** https://code.claude.com/docs/en/overview

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/code.claude.com/docs/en/overview"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://code.claude.com/docs/en/overview" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/agents/claude-code.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `agents/opencode.md` — alternative agent runtime, also baked in `/opt/agents/`
- `agents/openspec.md` — the workflow Claude Code is expected to follow on this project
- `runtime/forge-container.md` — the sandbox Claude Code lives in
- `runtime/external-logs.md` — full cheatsheet-telemetry schema + auditor invariants
- `runtime/cheatsheet-tier-system.md` — the tier system the telemetry events surface
