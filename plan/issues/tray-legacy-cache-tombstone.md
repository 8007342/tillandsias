# Task: Retire Legacy Cache Specs (overlay-mount-cache, tools-overlay-fast-reuse)

**Status**: Completed 2026-05-14
**Superseded by**: `forge-cache-dual`

## Summary

Formal retirement of two legacy cache specifications that were explored but not retained in the live contract. Both are replaced by the dual-cache architecture implemented in `forge-cache-dual`.

## What Was Done

### 1. Updated Old Specs with @tombstone Annotations

- **File**: `openspec/specs/overlay-mount-cache/spec.md`
  - Added `@tombstone superseded:forge-cache-dual` comment
  - Documented last live version: v0.1.260513 (2026-05-14)
  - Safe to delete after: v0.1.260515

- **File**: `openspec/specs/tools-overlay-fast-reuse/spec.md`
  - Added `@tombstone superseded:forge-cache-dual` comment
  - Documented last live version: v0.1.260513 (2026-05-14)
  - Safe to delete after: v0.1.260515

Both specs now include rationale for why the dual-cache model supersedes them.

### 2. Updated Litmus Bindings

- **File**: `openspec/litmus-bindings.yaml`
  - Added `tombstone: superseded:forge-cache-dual` field to both entries
  - Updated `last_verified` timestamp to 2026-05-14

This makes the tombstone relationship explicit in the bindings registry.

### 3. Updated Cheatsheet References

- **File**: `cheatsheets/runtime/cache-architecture.md`
  - Updated `@trace` annotation from `spec:overlay-mount-cache, spec:tools-overlay-fast-reuse` → `spec:forge-cache-dual`
  - Updated "Related Specs" section to reference live specs only:
    - `spec:forge-cache-dual` (the replacement)
    - `spec:forge-hot-cold-split` (related)
    - `spec:init-incremental-builds` (related)

## Retention Window

**Three-release retention rule** (per CLAUDE.md methodology):
- Last live: v0.1.260513
- Tombstone retained through: v0.1.260514 (today)
- Safe to delete after: v0.1.260515

After v0.1.260515 is shipped, the tombstoned specs can be permanently deleted.

## Migration Path

**No action required for users or developers**. The dual-cache architecture is already live and active. This change only formalizes the retirement of two superseded proposals.

### For agents reading logs:
Traces to `overlay-mount-cache` or `tools-overlay-fast-reuse` now resolve to tombstoned specs with clear cross-references to `forge-cache-dual`.

### For maintainers:
The litmus bindings now explicitly document which spec supersedes each obsolete entry, making the convergence path traceable in the registry.

## Verification

All changes are source-level (no breaking code changes):
- Specs remain readable with clear migration guidance
- Cheatsheet correctly references live spec
- Litmus bindings properly document tombstone relationship

## Related Specs

- `spec:forge-cache-dual` — Live dual-cache architecture (shared Nix + per-project overlay)
- `spec:forge-hot-cold-split` — RAM-backed vs disk-backed path separation
- `spec:init-incremental-builds` — Incremental build caching
