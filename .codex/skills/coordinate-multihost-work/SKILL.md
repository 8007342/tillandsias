---
name: coordinate-multihost-work
description: Coordinate Tillandsias Linux, Windows, and macOS implementation agents by auditing shared plan/methodology ledgers, reconciling stale work queues, surfacing blockers, assigning unclaimed work, maintaining plan/loop_status.md, and pushing coordination-only fixes to origin/linux-next. Use when invoked as /coordinate-multihost-work or when asked to run the Tillandsias multi-host coordination loop.
---

# Coordinate Multi-Host Work

Run a short, durable coordination pass for the Tillandsias Linux, Windows, and
macOS implementation agents. The goal is to keep agents unblocked and converging
on the specs without relying on chat history.

## Core Rule

Do coordination, spec, plan, methodology, and cheatsheet work. Do not change
implementation code unless the blocker is clearly a small coordination-side fix
required to unblock agents. Respect dirty worktree changes you did not make.

## Start Of Loop

1. Fetch origin.
2. Prefer `linux-next` for shared coordination files. If already on another
   branch, do not discard local changes; switch only when clean or safe.
3. Fast-forward/pull the latest `origin/linux-next` before editing shared
   coordination files.
4. Read:
   - `methodology.yaml`
   - `methodology/distributed-work.yaml`
   - `methodology/multi-host-development.yaml`
   - `plan.yaml`
   - `plan/index.yaml`
   - `plan/loop_status.md` if present
   - active `plan/issues/*work-queue*`
   - active `plan/issues/*blocker*`
   - active `plan/issues/multi-host-integration-loop-*.md`

## Audit

- Compare work-item headers against terminal events. If the latest terminal
  event says done, stalled, blocked, failed, or released, reconcile the header.
- Update dependency mirror tables in the same pass when a gate changes.
- Identify the current high-level dependency chain across Linux, Windows, and
  macOS: what is blocked, who owns it, what evidence exists, and what should
  happen next.
- If a host is stale, blocked, or working from outdated assumptions, append a
  concise feedback/blocker request in the relevant plan issue.
- Assign unclaimed ready work by adding or updating a stable work item with:
  `id`, `owner_host`, `capability_tags`, `status`, dependencies, owned files,
  expected evidence, and next action.
- Prefer pinging or reassigning stale work over duplicating work. Respect active
  leases unless expired or explicitly released.

## Loop Status Cache

Maintain `plan/loop_status.md` as a short quick-start cache. Rewrite and
distill it each loop; do not append forever. Keep it under roughly 80 lines.

Include:

- `LastExecutionTime` in UTC
- brief summary of this loop
- expected outcomes for the next loop
- major blockers resolved since the previous loop
- current major blockers and assigned workers
- stale or pending pings
- files changed and validation run

Move durable details into the owning plan issue and leave only pointers in
`plan/loop_status.md`.

## Skill Self-Improvement

If the coordination procedure itself needs refinement, update this skill in the
same coordination commit. Keep the skill concise and durable. Do not encode
single-run facts here; put those in `plan/loop_status.md` or the owning
`plan/issues/` file.

## Validation And Commit

- Validate touched YAML with a focused parser check.
- For Markdown-only changes, run `git diff --check` on touched files.
- If any durable coordination file changed (`plan/**`, `methodology/**`,
  `openspec/**`, `cheatsheets/**`, `.codex/skills/**`, or `codex`), commit and
  push those changes to `origin/linux-next` before ending the loop.
- Plan updates are not useful until remote agents can pull them. Every loop
  that edits `plan/**` MUST push the resulting commit to `origin/linux-next`.
- If the push is rejected because `origin/linux-next` advanced, fetch, rebase,
  re-run focused validation, and retry the push. If still blocked, write the
  blocker into `plan/loop_status.md` and report it in the final response.
- If no durable coordination files changed, do not create an empty commit; say
  that no push was needed.
- Use a clear checkpoint-style commit message that states what changed, what
  remains, what was verified, current blockers, and next action.

## Final Response

Report:

- `LastExecutionTime`
- short summary of changes
- expected outcomes for the next loop
- blockers resolved since the previous loop
- current major blockers and assigned workers
