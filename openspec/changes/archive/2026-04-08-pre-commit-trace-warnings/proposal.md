# Pre-Commit Trace Warnings

## Problem

An audit found 8 ghost traces (referencing non-existent specs), 12 specs with zero code traces (35% disconnected), and no automated staleness detection for active changes. These gaps accumulate silently because nothing surfaces them during normal development workflow.

## Proposal

Add a non-blocking pre-commit hook that warns about:
1. **Ghost traces** — `@trace spec:<name>` annotations pointing to specs that don't exist
2. **Zero-trace specs** — specs with no `@trace` references in the codebase
3. **Stale changes** — active OpenSpec changes older than 7 days

The hook follows the CRDT-inspired monotonic convergence philosophy: warnings nudge improvement but NEVER block commits. Every commit succeeds regardless of warnings. Over time, developers see the warnings and fix them organically.

## Scope

- `scripts/hooks/pre-commit-openspec.sh` — the hook itself
- `scripts/install-hooks.sh` — idempotent installer (symlink/append to `.git/hooks/pre-commit`)
- Scans `.rs`, `.sh`, `.toml` files for trace patterns
- Checks `openspec/specs/` for spec existence
- Checks `openspec/changes/` for `created:` date staleness

## Non-Goals

- No CI integration (local-only)
- No automatic fixing of ghost traces or missing annotations
- No blocking behavior under any circumstances
