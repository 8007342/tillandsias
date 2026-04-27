# OpenSpec Workflow

@trace spec:agent-source-of-truth

**Version baseline**: OpenSpec v0.2+ (baked at /opt/agents/openspec)  
**Use when**: Creating/applying/archiving OpenSpec changes, understanding the artifact lifecycle

## Provenance

- https://github.com/8007342/tillandsias/blob/main/openspec/ — Tillandsias OpenSpec specs and examples
- **Last updated:** 2026-04-27

## Quick reference

| Command | Artifact | Purpose |
|---------|----------|---------|
| `openspec new change --name my-change` | proposal.md | Propose a new change; describes intent, goals |
| `openspec instructions design` | design.md | Get template for design (decisions, trade-offs, risks) |
| `openspec instructions specs` | specs/ | Get template for spec files (one per capability) |
| `openspec instructions tasks` | tasks.md | Get template for tasks (implementation checklist) |
| `openspec validate` | all | Lint all artifacts (cross-references, format) |
| `openspec status` | all | Show change status (% complete) |
| `openspec archive --change my-change` | archive/ | Archive completed change; syncs delta specs to main |

## Common patterns

**Starting a new change:**
```bash
# Create skeleton with proposal
openspec new change --name forge-offline-mode

# Gets a proposal.md template
# Edit: describe the problem, goals, non-goals

# View instructions for the next artifact (design)
openspec instructions design

# Write design.md (decisions, trade-offs, sources of truth)
# Then: openspec instructions specs (repeatable for each spec)
```

**Running the artifact lifecycle:**
```bash
# 1. Propose (describe intent)
openspec new change --name my-feature

# 2. Design (decisions + reasoning)
openspec instructions design
# [Write design.md]

# 3. Specify (per-capability specs)
openspec instructions specs
# [Write specs/capability-1/spec.md, specs/capability-2/spec.md, ...]

# 4. Plan (implementation checklist)
openspec instructions tasks
# [Write tasks.md: numbered list of work]

# 5. Validate before implementation
openspec validate

# 6. Implement (use /opsx:apply, or manual)
# [Write code, tests, docs]

# 7. Verify implementation matches spec
openspec verify

# 8. Archive (move to archive/, sync specs)
openspec archive --change my-feature
```

**Validating cross-references:**
```bash
# Check that all specs exist, cheatsheet citations resolve, etc.
openspec validate

# Warnings (not errors) surface issues:
# - Missing ## Sources of Truth section in a new spec
# - Broken cross-references to other specs
# - Malformed YAML front-matter
```

**Checking change status:**
```bash
# See how much work is done
openspec status

# Output: percentage of tasks marked [x]
# Helps prioritize what remains
```

## Common pitfalls

❌ **Writing code before design is approved**: Specs are source of truth. Code that diverges from spec is a bug. → Always design first, write second.

❌ **Forgetting `## Sources of Truth` in new specs**: The spec methodology requires citing cheatsheets. → Check your spec has this section; `openspec validate` warns if missing.

❌ **Not filling in `## Provenance` in new cheatsheets**: Cheatsheets without source URLs are rejected. → Every cheatsheet: canonical reference URL + last updated date.

❌ **Archiving incomplete changes**: Each task must be marked `[x]` before archiving. → `openspec status` shows the checklist; finish all tasks first.

❌ **Running `openspec new change` when you meant to continue an existing one**: Creates duplicate. → Check `openspec status` for in-progress changes; use `openspec continue` instead.

## See also

- `agents/claude-code.md` — Claude Code for analysis and automated edits
- `runtime/forge-container.md` — Understanding the container where OpenSpec runs
