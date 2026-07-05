# Housekeeping: semantic distillation and stale-ledger pruning — 2026-07-05

- class: housekeeping+methodology
- owner: any
- status: ready
- order: 192
- trace: methodology/markdown-distillation.yaml, methodology/distributed-work.yaml,
  plan/metrics-dashboard.md

## Problem

The active ledger contains real work, historical intake, duplicate blockers, and
cache-empty dashboards in the same surface. That increases uncertainty because
agents can pick up stale requirements as if they were current.

Known examples from this audit:

- `plan/issues/embedded-guest-binary-packaging-implementation-2026-07-04.md`
  still says the local blocker is "macOS lacks rustup/cross targets", but order
  190 established the canonical Linux/Nix build contract.
- `plan/issues/embedded-guest-binary-packaging-research-2026-07-04.md` is useful
  intake evidence, but not the active implementation packet.
- `plan/issues/coord-osx-vz-fmt-drift-2026-06-28.md` remains in active issues
  even though a copy exists under `plan/archive/` and the current drift is the
  new 2026-07-05 secure-wire/embedded-guest branch drift.
- `plan/metrics-dashboard.md` contains empty chart data and blank latest metrics,
  so it must not be treated as a current performance signal.

## Work

1. Tombstone or archive active issue files whose current-state ownership has moved
   to orders 190/191.
2. Update dashboard generation so an empty metrics input emits an explicit
   "no current metrics" state with source timestamp/provenance instead of zeros.
3. Reconcile active issue status headers with `plan/index.yaml` for packets that
   are marked done in the index but pending/ready in the old Markdown body.
4. Keep only live blockers in the active issue queue; preserve historical detail
   through `plan/archive/` or a short tombstone pointer.

## Acceptance evidence

- `rg "rustup: command not found|operator cutting a release|blocked on research" plan/issues`
  returns only archived/tombstoned historical context, not active blocker text.
- `plan/metrics-dashboard.md` names its source file/timestamp or says there is no
  current metrics input.
- `plan/index.yaml` and active issue status headers agree for orders 178-192.
