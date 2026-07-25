# plan.yaml duplicate bootstrap-note lines + methodology/event vs events split

- date: 2026-07-24
- packet: `plan-yaml-duplicate-note-lines` (order 485, kind: housekeeping, status: ready)
- filed under the issue_filing_mandate (observed during the order-478 research wave; out of
  that wave's scope, so filed rather than fixed inline).

## Observed

1. `plan.yaml` notes list contains two near-identical entries (lines ~147–148), differing only
   in `./methodology/events/` vs `./methodology/event/`:
   - "When a task uncovers ambiguity ... file an immediate bootstrap note in `./plan/issues/`
     or `./methodology/events/` ..."
   - "When a task uncovers ambiguity ... file an immediate bootstrap note in `./plan/issues/`
     or `./methodology/event/` ..."
2. The ambiguity is real on disk: BOTH `methodology/event/` and `methodology/events/` exist.
   `methodology.yaml` entrypoints declare `unknown_event_register: methodology/event/index.yaml`
   (singular), while `plan/index.yaml` graph_policy refinement_notes says
   `./methodology/event/<event-id>.yaml` (singular) — but the plural directory also exists and
   is referenced by one of the duplicate notes.
3. Also observed: a stray `@methodology` directory at repo root next to `methodology/` —
   confirm whether it is intentional (symlink shim?) or leftover.

## Why it matters

Cold-start agents follow these pointers literally; a singular/plural fork means bootstrap notes
land in two places and event-register audits miss half of them. Duplicate instruction lines are
schema-drift noise in the file the methodology calls a "pointer surface".

## Root cause (hypothesis)

Two agents filed the same note independently, one with a typo'd path; the typo then got a
directory created for it (or vice versa). Confirm via `git log --follow methodology/event
methodology/events`.

## Exit criteria

- One canonical event directory (whichever `methodology.yaml` declares) with the other merged
  in and tombstoned per markdown-distillation rules.
- The duplicate note line in `plan.yaml` removed, leaving one entry with the canonical path.
- `@methodology` root entry explained or removed.
