# Optimization: Stale-Reference & Superseded-Work Cleanup Audit

**Status:** `ready`
**Owner:** linux
**Date:** 2026-06-28
**Kind:** optimization (plan + docs hygiene)
**Trace:** `methodology.yaml` (documentation policy), `openspec/`, `plan/issues/`

## Problem

References to removed/superseded work linger across the repo, confusing agents
(who read `plan/` every cycle) and inflating the maintenance surface. Confirmed
examples:

- **Removed zeroclaw** (orders 114/117 deleted the binary, crate, image, tray
  path) still referenced in: `plan/issues/zeroclaw-progress.md`,
  `plan/issues/nanoclawv2-orchestration.md`, `plan/secure_agent_forge_plan.md`,
  `TRACES.md` (tillandsias-zeroclaw binary), plus stale lines in
  `plan/issues/{ACTIVE,linux-next-work-queue,osx-next-work-queue}.md`.
- **32 `plan/issues/*2026-05-*.md`** files (6+ weeks old) — many describe shipped
  or abandoned waves (`wave-25/26`, `release-checklist-2026-05-14`, etc.).
- **Superseded-by-normalization** issues now coordinated under the host-guest
  transport initiative (orders 123–128): `control-socket-protocol-convergence`,
  `optimization-macos-vz-idiomatic-exec-layer`, `tray-convergence-coordination`,
  `windows-next-architecture-decision` should be tombstoned → superseded.

## Fix (audit → classify → tombstone/archive)

1. **Audit** every `plan/issues/*.md` and top-level `plan/*.md`: classify each as
   `active` / `shipped` / `superseded` / `obsolete`.
2. **Tombstone, don't delete** — superseded issues get a `**Superseded by:**
   <packet>` header and move to `plan/archive/` (per the archival packet); the
   `openspec/litmus-bindings.yaml` entries get `status: obsolete` +
   `tombstone: superseded:<spec>` (the pattern already used there).
3. **Remove dead pointers** — strip references to the removed zeroclaw binary
   from `TRACES.md`, `plan/secure_agent_forge_plan.md`, and the work-queue
   ledgers' live sections (keep historical ledger lines; only fix forward-looking
   "current state" prose).
4. **Verifiable**: a `litmus:no-dangling-removed-component-refs` (instant) that
   greps the LIVE doc set (excluding archive/ + dated historical ledgers) for
   `tillandsias-zeroclaw` / `ZeroClaw` and exits non-zero if any survive outside
   the sanctioned historical-record locations.

## Exit Criteria

- Every `plan/issues/*.md` classified; superseded ones tombstoned → archive.
- No `tillandsias-zeroclaw` / `ZeroClaw` reference in live (non-archive,
  non-historical-ledger) docs; `litmus:no-dangling-removed-component-refs` green.
- Superseded specs marked `obsolete` + `tombstone:` in litmus-bindings.
- A short `plan/archive/README.md` explaining the archive layout.

## Guardrails

- Coordinate with siblings — this touches shared `plan/` + `openspec/`; run during
  an integration lull / under the smoke lock to avoid colliding with osx/windows
  merges (the cross-branch-merge fragility this hygiene also reduces).
- Tombstone, never delete (preserve audit history).

## Related

- `plan-ledger-archival-2026-06-28.md` (the index-side archival; this is the issues/docs side)
- `methodology-concurrent-integration-duplication-2026-06-28.md`
- `plan/issues/markdown-distillation-audit-2026-05-24.md`
