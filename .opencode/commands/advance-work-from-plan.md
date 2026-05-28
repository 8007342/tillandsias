---
description: Pick the next bounded slice of READY work from the project plan and ship it. Agent-agnostic + host-aware.
---

Load and execute the canonical `advance-work-from-plan` skill at
`skills/advance-work-from-plan/SKILL.md` (also reachable via
`.opencode/skills/advance-work-from-plan/SKILL.md`, which is a symlink to
the same file).

## Input

- `$ARGUMENTS` — optional. If a packet path or work-queue slug is given,
  prefer it as the slice source.

## Procedure

See `skills/advance-work-from-plan/SKILL.md`. The skill covers:

1. Host detection (linux / macOS / Windows → active branch).
2. Refresh + clean-tree check.
3. Work discovery from `plan/index.yaml` and `plan/issues/<host>-next-*`.
4. Bounded slice selection (30 min – 2 h).
5. Soft scope guidance + unblock-with-NOOP escape hatch for sibling scopes.
6. Build / test verification.
7. Commit + push + ledger entry (with defer rule when the integration
   cron just fired).
8. One-line output to the invoker.

The skill is **mutable** — an orchestrator can edit
`skills/advance-work-from-plan/SKILL.md` between iterations to steer
remote agent work. Read the latest committed version every time you
invoke this command. Do NOT cache an old copy of the skill content.
