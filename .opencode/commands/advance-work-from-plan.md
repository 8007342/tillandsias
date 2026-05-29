---
description: Discover, claim, implement, checkpoint, and complete units of work from the shared plan ledger based on host capabilities and lease rules. Worker tier of the two-tier execution model (Orchestrator tier is /multihost-orchestration). Spec at methodology/distributed-work.yaml worker_agent_protocol.
---

Load and execute the canonical `advance-work-from-plan` skill at
`skills/advance-work-from-plan/SKILL.md` (also reachable via
`.opencode/skills/advance-work-from-plan/SKILL.md`, which is a symlink
to the same file).

This is the **Worker tier** of the two-tier execution model documented
in `methodology/distributed-work.yaml` (`agent_execution_roles` +
`worker_agent_protocol`). Complementary to the **Orchestrator tier**
(`/multihost-orchestration` → `/coordinate-multihost-work`).

## Input

- `$ARGUMENTS` — optional. If a packet path, work-queue slug, or task
  ID is given, prefer it as the slice source.

## Procedure

See `skills/advance-work-from-plan/SKILL.md`. The skill covers:

1. **Orient & discover environment** — fetch + checkout linux-next,
   identify host/agent/capabilities, mint Agent ID, read the
   authoritative ledgers.
2. **Discover work & select a shaped packet** — walk the plan graph,
   filter by `owner_host`/`status`/`capability_tags`/lease, apply
   selection priority.
3. **Claim the lease** — emit a `claim` event under the task's
   `events:` YAML, push to `linux-next`, yield on collision.
4. **Host write scope + unblock-with-NOOP** — soft scope guidance;
   minimal stub allowed in sibling scopes with `// PLEASE REVIEW`
   when needed.
5. **Execute & verify** — `cargo fmt`, `./build.sh --check`, targeted
   tests, `./build.sh --test` for cross-cutting changes.
6. **Commit, push & checkpoint** — durable `agent_status_packet`
   checkpoints every 30–45 min; targeted `git add`; ledger entry per
   host's work-queue file; defer rule when the 2h integration cron
   just fired.
7. **Submit completion or yield** — `completed`/`blocked`/`failed`
   event on the task; fallback selection on yield.

The skill is **mutable** — an orchestrator can edit
`skills/advance-work-from-plan/SKILL.md` between iterations to steer
remote agent work. Always read the latest committed version on
invoke; do NOT cache an old copy.
