# OpenSpec — workflow + CLI

@trace spec:agent-cheatsheets

> ⚠️ **DRAFT — provenance pending.** This cheatsheet was generated before the provenance-mandatory methodology landed. Treat its content as untrusted until the `## Provenance` section below is populated and verified against authoritative sources. See `cheatsheets/runtime/runtime-limitations.md` to report errors. (Tracked under change `cheatsheet-methodology-evolution`.)

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

## See also

- `agents/claude-code.md` — Claude Code's hooks/skills layer that often runs OpenSpec commands
- `agents/opencode.md` — OpenCode's invocation of `/opsx:*` slash commands
- `runtime/forge-container.md` — where these specs eventually run (the forge)
