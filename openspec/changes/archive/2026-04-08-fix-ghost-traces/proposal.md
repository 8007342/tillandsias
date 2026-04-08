# Proposal: Fix Ghost Trace Annotations

## Problem

A methodology audit found 8 `@trace spec:X` annotations in code referencing specs that don't exist in `openspec/specs/`. These "ghost traces" break the bidirectional link between specs and implementation that OpenSpec depends on.

The root causes:

1. **Archived but not synced (6 specs)**: Changes were archived but their delta specs were never promoted to `openspec/specs/`. The traces in source code point to specs that only exist in archive directories.
2. **Typo in trace name (1 occurrence)**: `spec:secrets-management` (plural) instead of `spec:secret-management` (singular).
3. **Wrong spec name (2 occurrences)**: `spec:podman-lifecycle` instead of the correct `spec:podman-orchestration`.
4. **Placeholder not yet cleaned (1 occurrence)**: `spec:name` in `log_format.rs` was a format example that should reference the actual spec.
5. **Already resolved (1 spec)**: `spec:secret-management` was created by a concurrent agent.

## Solution

- Promote 6 archived delta specs to `openspec/specs/`: clickable-trace-index, cross-platform, install-progress, logging-accountability, secret-rotation, tray-icon-lifecycle
- Copy `secret-management` spec (created by concurrent agent on linux-next)
- Fix `spec:name` placeholder in `log_format.rs` to `spec:logging-accountability`
- Fix `spec:podman-lifecycle` to `spec:podman-orchestration` in 2 cheatsheets
- Fix `spec:secrets-management` typo to `spec:secret-management` in 1 cheatsheet

## Impact

Zero ghost traces in source code and documentation after this change. All `@trace spec:X` annotations resolve to an existing `openspec/specs/X/spec.md`.
