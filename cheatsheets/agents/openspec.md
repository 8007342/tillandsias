---
tags: [openspec, workflow, spec-driven, change-management, agent-workflow, cli]
languages: []
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://github.com/8007342/tillandsias/blob/main/openspec/specs/agent-cheatsheets/spec.md
  - https://github.com/8007342/tillandsias/blob/main/CLAUDE.md
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# OpenSpec — workflow + CLI

@trace spec:agent-cheatsheets

## Provenance

OpenSpec is Tillandsias-internal tooling; the authority is the project itself.
- OpenSpec agent-cheatsheets spec (defines the workflow this cheatsheet describes): <https://github.com/8007342/tillandsias/blob/main/openspec/specs/agent-cheatsheets/spec.md>
- Tillandsias CLAUDE.md (OpenSpec workflow rules, `/opsx:*` command conventions): <https://github.com/8007342/tillandsias/blob/main/CLAUDE.md>
- **Last updated:** 2026-04-25

**Version baseline**: `@fission-ai/openspec` baked at `/opt/agents/openspec/` (linked into PATH as `openspec`)
**Use when**: starting any non-trivial change. NO exceptions for "quick fixes" — the spec trail IS the proof of work.

## Quick reference

| Command | Effect |
|---|---|
| `openspec new change <name>` | scaffold `openspec/changes/<name>/` with `.openspec.yaml` |
| `openspec instructions <artifact> --change <name> --json` | get the per-artifact template + rules |
| `openspec status --change <name> --json` | machine-readable artifact status |
| `openspec status --change <name>` | human-readable status |
| `openspec validate <name> --strict` | strict validation; fail on missing required artifacts |
| `openspec list --json` | every change in `openspec/changes/` |

| Artifact (in dependency order) | Purpose |
|---|---|
| `proposal.md` | WHY: 1-2 sentences, What Changes bullets, Capabilities table, Impact |
| `design.md` | HOW: Context, Goals/Non-Goals, Decisions (with alternatives rejected), Risks/Trade-offs, Sources of Truth |
| `specs/<cap>/spec.md` | WHAT: Requirements + Scenarios (`### Requirement:` + `#### Scenario:`); use `## ADDED`, `## MODIFIED`, `## REMOVED`, `## RENAMED` headers; MUST include `## Sources of Truth` |
| `tasks.md` | implementation checklist; `- [ ] N.M Task description` checkboxes |

## Common patterns

### Pattern 1 — start a brand-new change

```bash
openspec new change feature-foo
openspec status --change feature-foo --json    # see what artifacts to write next
openspec instructions proposal --change feature-foo --json   # get the proposal template
# ...write proposal.md, then design.md, then specs/<cap>/spec.md, then tasks.md
openspec validate feature-foo --strict
```

### Pattern 2 — modify an existing capability (delta spec)

```markdown
## MODIFIED Requirements

### Requirement: <exact existing requirement name>

<full new content — copy the entire existing block, then edit it. Partial content
loses detail at archive time.>

#### Scenario: <name>
- **WHEN** ...
- **THEN** ...
```

The header text inside `### Requirement:` SHALL match the existing requirement name byte-for-byte (whitespace-insensitive). Otherwise the delta resolves to a new requirement and the old one stays orphaned.

### Pattern 3 — every spec ends with Sources of Truth

```markdown
## Sources of Truth

- `cheatsheets/runtime/forge-container.md` — runtime constraints constrain my design
- `cheatsheets/utils/git.md` — pinned the git version for the `git switch` semantics this spec relies on
```

Mandatory. `openspec validate` warns if missing. See `agents/openspec.md` itself + the project CLAUDE.md.

### Pattern 4 — scenarios use exactly four hashtags

```markdown
### Requirement: <name>

<requirement text using SHALL / MUST>

#### Scenario: <name>
- **WHEN** <condition>
- **THEN** <expected outcome>
```

Three hashtags or bullets fail silently — the validator skips them and the requirement looks scenarios-less. Always exactly `####`.

### Pattern 5 — verify before archive

```bash
openspec validate <name> --strict          # zero errors required to archive
# if /opsx:verify is available, run that too — it cross-checks code vs spec.
```

After archive, the change's deltas sync into `openspec/specs/<cap>/spec.md` and the change directory moves to `openspec/changes/archive/<date>-<name>/`.

## Common pitfalls

- **Three hashtags on a Scenario heading** — silent fail. Use `####` exactly.
- **Partial MODIFIED content** — copy the ENTIRE original requirement block first, then edit. Partial blocks lose details at archive time.
- **Missing `## Sources of Truth`** — produces a warning. New specs MUST have it; existing pre-convention specs are exempt until a separate sweep change.
- **`### Requirement:` name not matching the existing requirement** — your MODIFIED becomes ADDED and the original stays orphaned. Whitespace-insensitive match required.
- **Skipping `openspec validate --strict`** — the validator catches missing scenarios, malformed front-matter, and duplicate requirement names before archive. Run it before every commit that touches a change.
- **Editing main specs directly** — never. All changes flow through `openspec/changes/<name>/specs/<cap>/spec.md` deltas, then sync at archive. Direct edits to `openspec/specs/<cap>/spec.md` break the audit trail.
- **Archiving without user verification** — even if validate is green, the human-in-the-loop verification gate (manual UI test, real-world smoke) precedes archive. The agent prepares; the human archives.
- **Forgetting to add the change name to the commit message** — commits should include `OpenSpec change: <name>` near the bottom so the link from commit to change is explicit. Also include the `@trace spec:<cap>` GitHub search URL.

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
  - `https://github.com/8007342/tillandsias/blob/main/openspec/specs/agent-cheatsheets/spec.md`
- **Archive type:** `single-html`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/github.com/8007342/tillandsias/blob/main/openspec/specs/agent-cheatsheets/spec.md`
- **License:** see-license-allowlist
- **License URL:** https://github.com/8007342/tillandsias/blob/main/openspec/specs/agent-cheatsheets/spec.md

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/github.com/8007342/tillandsias/blob/main/openspec/specs/agent-cheatsheets/spec.md"
mkdir -p "$(dirname "$TARGET")"
curl --fail --silent --show-error \
  "https://github.com/8007342/tillandsias/blob/main/openspec/specs/agent-cheatsheets/spec.md" \
  -o "$TARGET"
```

### Generation guidelines (after pull)

1. Read the pulled file for the structure relevant to your project.
2. If the project leans on this tool/topic heavily, generate a project-contextual
   cheatsheet at `<project>/.tillandsias/cheatsheets/agents/openspec.md` using
   `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter:
   `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`,
   `committed_for_project: true`.
4. Cite the pulled source under `## Provenance` with `local: <cache target above>`.

## See also

- `agents/claude-code.md` — Claude Code's hooks/skills layer that often runs OpenSpec commands
- `agents/opencode.md` — OpenCode's invocation of `/opsx:*` slash commands
- `runtime/forge-container.md` — where these specs eventually run (the forge)
