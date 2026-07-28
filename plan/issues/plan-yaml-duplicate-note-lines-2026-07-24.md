# plan.yaml duplicate bootstrap-note lines + methodology/event vs events split

- date: 2026-07-24
- packet: `plan-yaml-duplicate-note-lines` (order 485, kind: housekeeping, status: completed)
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

## Root cause

Two agents filed the same note independently, one with a typo'd path; the typo then got a
directory created for it (or vice versa). Confirmed via `git log --follow` — `methodology/events/`
was created by commit 403379fb (checkpoint(codex): add verbose noisy mode) as a parallel
registration path; the singular `methodology/event/` is the original declared in methodology.yaml.

## Resolution (2026-07-28)

1. **Duplicate note line removed**: `plan.yaml` line 147 (the `events/` plural variant) deleted;
   line 148 (the `event/` singular variant, matching `methodology.yaml`) retained.
2. **`methodology/events/` directory removed**: contained only a `README.md` with usage
   guidelines. The canonical `methodology/event/` directory (with `index.yaml` and 17 event
   files) is the sole event register. `methodology/markdown-distillation.yaml` whitelist entry
   for `methodology/events/README.md` removed. `scripts/check-markdown-distillation.sh`
   whitelist pattern for `methodology/events/README.md` removed.
3. **`@methodology/` explained**: tracked directory containing stale copies of
   `.opencode/commands/` and `.opencode/skills/` (4 commands, 4 skills). Created intentionally
   in commit 54ef8f30 (chore: unify repeat orchestration) as an OpenCode config overlay. Files
   are older versions of the canonical `.opencode/` content — staleness is a separate
   housekeeping item, not a correctness issue. Left in place; whitelisted by
   `scripts/check-markdown-distillation.sh` line 17.

## Remaining observation

`@methodology/.opencode/` carries stale copies of commands and skills (4 commands vs 12 in
`.opencode/commands/`, 4 skills vs the full set). A future cleanup should either sync or remove
the stale overlay, but that is outside this packet's scope.
