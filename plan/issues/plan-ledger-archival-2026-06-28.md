# Optimization: Archive Closed Packets out of plan/index.yaml

**Status:** `ready`
**Owner:** linux
**Date:** 2026-06-28
**Kind:** optimization (plan hygiene)
**Trace:** `methodology.yaml` (plan discipline), `plan/index.yaml`

## Problem

`plan/index.yaml` is **7870 lines** and **~92% closed work**:

| status | count |
|---|---|
| completed | 84 |
| done | 41 |
| obsoleted | 4 |
| in_progress | 4 |
| ready | 3 |
| pending | 3 |
| claimed | 1 |

Every agent reads the whole index each `/advance-work-from-plan` cycle (skill §1).
129 closed packets bury the ~11 active ones, slow selection, inflate the
diff/merge surface (a contributing factor to the cross-branch merge conflicts and
the duplication incident), and make the ledger hard to scan.

## Fix

Move closed packets (`completed` / `done` / `obsoleted` / `success`) to a
date-partitioned archive that preserves full history but is NOT loaded in the hot
selection path:

- `plan/archive/index-archive-2026-Q2.yaml` (or per-month) holding the closed
  packet blocks verbatim, with a one-line pointer index.
- `plan/index.yaml` keeps only `ready` / `pending` / `in_progress` / `claimed` /
  `failed-retryable` + a short "recently archived" tail.
- A small script `scripts/archive-plan-packets.sh` that moves any packet whose
  terminal status is older than N days into the archive and validates both YAML
  files parse — so archival is mechanical and idempotent, not hand-editing.

## Verifiable Closure

- `plan/index.yaml` line count drops to roughly the active set (target < ~1500 lines).
- `ruby -ryaml -e "YAML.load_file(...)"` parses both `index.yaml` and the archive.
- No packet is lost: `closed_count(before) == archived_count + closed_remaining`.
- `scripts/archive-plan-packets.sh --check` is idempotent (re-run = no-op).
- `/advance-work-from-plan` still finds every eligible active packet.

## Guardrails

- **Tombstone, don't delete** — archival MOVES blocks, it never drops them
  (methodology: "NEVER resolve cross-host plan conflicts by deletion").
- Keep `events:` history intact in the archive (audit trail).
- Coordinate the cutover with siblings (a one-time large index rewrite must not
  collide with an in-flight osx/windows merge — run under the integration lull or
  the smoke lock).

## Related

- `methodology-concurrent-integration-duplication-2026-06-28.md` (smaller index → smaller merge surface)
- `plan/issues/markdown-distillation-audit-2026-05-24.md` (the distillation discipline)
