---
name: "advance-work-from-plan"
description: Discover, claim, implement, checkpoint, and complete units of work from the shared plan ledger based on host capabilities and lease rules. Complementary to /multihost-orchestration (the orchestrator tier). Authoritative spec at methodology/distributed-work.yaml worker_agent_protocol.
category: Workflow
tags: [workflow, multi-host, worker-protocol]
---

Run the canonical `advance-work-from-plan` skill — the **Worker tier** of
the two-tier execution model documented in
`methodology/distributed-work.yaml` (`agent_execution_roles` +
`worker_agent_protocol`). Complementary to the **Orchestrator tier**
(`/multihost-orchestration` → `/coordinate-multihost-work`).

**Input**: `$ARGUMENTS` (optional). If a packet, work-queue path, or
specific task ID is given, prefer it as the slice source.

**Steps**

Load and execute the procedure defined at
`skills/advance-work-from-plan/SKILL.md` (the same file is reachable
via `.claude/skills/advance-work-from-plan/SKILL.md`, which is a
symlink). The canonical skill covers:

1. **Orient & discover environment** — fetch + checkout linux-next,
   identify host/agent/capabilities, mint a unique Agent ID, read the
   authoritative ledgers (`methodology.yaml`,
   `methodology/distributed-work.yaml`, `plan.yaml`, `plan/index.yaml`,
   `plan/loop_status.md`).
2. **Discover work & select a shaped packet** — walk the plan graph,
   filter eligible by `owner_host`, `status`, `capability_tags`, lease
   availability; apply the selection priority list.
3. **Claim the lease** — mint a content-stable lease ID, emit a `claim`
   event under the task's `events:` YAML, push to `linux-next`. Yield on
   collision.
4. **Host write scope & unblock-with-NOOP** — soft scope guidance per
   host; minimal stub allowed in sibling scopes with `// PLEASE REVIEW:
   <sibling>` annotation when needed to unblock work.
5. **Execute & verify** — `cargo fmt`, `./build.sh --check`, targeted
   tests, `./build.sh --test` for cross-cutting changes.
6. **Commit, push & checkpoint** — durable `agent_status_packet`
   checkpoints every 30–45 min; targeted `git add` (never `-A`);
   ledger entry per host's work-queue file; defer rule when the 2h
   integration cron just fired.
7. **Submit completion or yield** — `completed` event with SHA + log
   paths on success; `blocked`/`failed` event with diagnostic on
   blockage; fallback selection on yield.

The skill is **mutable** — an orchestrator can edit
`skills/advance-work-from-plan/SKILL.md` between iterations to steer
remote agent work. Always read the latest committed version on invoke.
