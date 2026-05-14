---
name: haiku-delegate
description: Delegate small bounded Tillandsias tasks to Claude Haiku workers while the primary agent keeps ownership of specs, integration, verification, and commits.
---

# Haiku Delegate

Use this skill for cheap parallel side work only: file inventory, stale-reference audits,
tiny patch drafts, log summarization, and merge/conflict notes. Do not use it for
architecture decisions, spec convergence calls, release decisions, or final commits.

## Rules

- The primary agent remains accountable for scope, methodology, verification, and integration.
- Prefer read-only audits. Ask for paths, line references, and a concise finding list.
- For code changes, ask for a unified diff or explicit file/path instructions. Do not let workers commit.
- Give workers a bounded task, relevant files, and the expected output shape.
- Tell workers they are not alone in the repo and must not revert unrelated changes.
- Treat worker output as a draft. Re-read affected files before applying anything.

## Wrapper

Use `scripts/claude-delegate.sh`:

```bash
scripts/claude-delegate.sh audit "Find stale Tauri references in scripts only. Return path:line and recommended action."
scripts/claude-delegate.sh patch-draft "Draft a minimal patch for build.sh help text replacing AppImage wording with native binary wording."
scripts/claude-delegate.sh json "Summarize /tmp/litmus-check.log into top failure classes."
```

For MCP clients, use `scripts/claude-mcp.sh` as the stdio server. It exposes
`claude.audit`, `claude.patch_draft`, and `claude.json` by delegating to the
same wrapper above.

Modes:

- `audit`: read-only repository analysis, text output.
- `patch-draft`: read-only repository analysis that outputs a proposed diff, not edits.
- `json`: read-only repository analysis with JSON output.
