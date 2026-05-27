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

This skill is also the active runtime orchestrator. If a sibling branch has
eligible code ahead of `linux-next`, do not only recommend that a future loop
merge/test it. Pull/merge what can be merged, then start or monitor the full
runtime litmus run so the next loop has concrete output to read.

## Start Of Loop

1. Fetch origin.
2. Prefer `linux-next` for shared coordination files. If already on another
   branch, do not discard local changes; switch only when clean or safe.
3. Fast-forward/pull the latest `origin/linux-next` before editing shared
   coordination files.
   - Expect `origin/linux-next` to be ahead of a recurrent agent's local
     checkout on most runs. That is healthy evidence that another agent or the
     integration loop made progress. Treat a non-advancing remote head across
     repeated cycles as the suspicious signal, not the other way around.
   - If remote advanced, fresh-read the changed ledgers and reconcile them; do
     not report remote-ahead as a blocker unless local dirty state prevents
     fetch/rebase/merge.
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
- Track remote progress as a health signal: document the latest observed heads
  and the delta since the previous loop. If `origin/linux-next` or active
  sibling branches do not advance for multiple expected cycles, record that
  no-progress streak and what host or job should be checked.
- Update dependency mirror tables in the same pass when a gate changes.
- Identify the current high-level dependency chain across Linux, Windows, and
  macOS: what is blocked, who owns it, what evidence exists, and what should
  happen next.
- Shape work before assigning it. Prefer platform-sized packets that can occupy
  an agent for one or two cron iterations and produce useful evidence. Avoid
  publishing tiny one-file chores as standalone work unless they unblock another
  host or are the last step before completion.
- Keep ready work eager: every active host should have at least one claimed or
  ready unblocked packet, plus one named fallback packet when its primary work
  is blocked. If a queue has only gated work, create or surface a verification,
  packaging, CI, or diagnostics packet that can progress independently.
- If a host is stale, blocked, or working from outdated assumptions, append a
  concise feedback/blocker request in the relevant plan issue.
- Assign unclaimed ready work by adding or updating a stable work item with:
  `id`, `owner_host`, `capability_tags`, `status`, dependencies, owned files,
  expected evidence, and next action.
- When assigning work, include an `agent_status_packet` expectation: current
  plan, dependencies, blockers/errors, files touched, evidence produced, next
  checkpoint, and whether the lease should continue, release, or be reclaimed.
- Prefer pinging or reassigning stale work over duplicating work. Respect active
  leases unless expired or explicitly released.

## Integration And Runtime Executor

Run this before ending the loop whenever `origin/windows-next` or
`origin/osx-next` is not an ancestor of `origin/linux-next`, or whenever the
latest integrated code has not yet been exercised by the full runtime litmus.

1. Check for an active async runtime run under
   `plan/localwork/runtime-litmus/current`.
   - If present, read `metadata.env`, `status`, and `run.log`.
   - If the pid is still alive, record a short "validation still running"
     update in `plan/loop_status.md` and do not start a second run.
   - If it finished, fold the result into
     `plan/issues/multi-host-integration-loop-*.md`, then remove or replace
     the `current` symlink/file.
2. If no run is active, compute sibling deltas with:
   - `git merge-base --is-ancestor origin/windows-next origin/linux-next`
   - `git merge-base --is-ancestor origin/osx-next origin/linux-next`
   - `git rev-list --left-right --count origin/linux-next...origin/<sibling>`
3. If a sibling has unique commits, attempt a real merge in a fresh worktree.
   Prefer Windows first when both have deltas because Windows currently carries
   the larger runtime surface; otherwise merge every eligible sibling in one
   run, one branch at a time.
4. Never write "next loop should merge/test" unless this loop either started a
   run, observed an already-running run, or recorded a concrete reason the run
   could not start.

### Async Runtime Litmus Run

Use ignored local state only:

- run directory: `plan/localwork/runtime-litmus/<run_id>/`
- current marker: `plan/localwork/runtime-litmus/current`
- worktree: `/tmp/tillandsias-runtime-litmus-<run_id>`
- log: `plan/localwork/runtime-litmus/<run_id>/run.log`
- metadata: `plan/localwork/runtime-litmus/<run_id>/metadata.env`
- status file: `plan/localwork/runtime-litmus/<run_id>/status`

Run id format: `YYYYMMDDTHHMMSSZ-<linux>-<windows>-<osx>`.

The background run MUST:

1. Create a fresh worktree from `origin/linux-next`.
2. Merge `origin/windows-next` if it is ahead; then merge `origin/osx-next` if
   it is ahead.
3. On conflicts, stop immediately with `status=failed` and leave `git status`,
   conflicted paths, and merge output in `run.log`.
4. Preserve newer `linux-next` coordination files and known manifest repins
   when resolving only if the resolution is mechanical and already documented in
   the active ledger. Otherwise fail and assign a conflict-resolution packet.
5. Run the full installed runtime mechanism, saving all stdout/stderr to
   `run.log`:
   - `./build.sh --ci-full --install`
   - `tillandsias --debug --init`
   - `tillandsias . --opencode --diagnostics --prompt "$LITMUS_PROMPT"`
6. Use `TILLANDSIAS_LITMUS_PROMPT` when set. Otherwise use this default prompt:
   `Run a Tillandsias runtime litmus for this checkout. Exercise OpenCode
   startup, diagnostics, container readiness, and report exact failures with
   commands and log paths.`
7. On success, commit the merge with a checkpoint-style message and push
   `HEAD:linux-next`.
8. On push rejection, mark `status=stale-push`; the next loop must fetch and
   start a fresh run rather than force-pushing.

The parent coordinator loop records the run id, pid, heads, worktree, log path,
and next reader action in `plan/loop_status.md` before ending.

## Assignment Board

Every loop must publish or refresh a three-host assignment board in
`plan/loop_status.md`:

- Linux primary and fallback.
- Windows primary and fallback.
- macOS primary and fallback.

Rules:

- If a host has an in-progress item, name the next checkpoint expected in the
  next one or two cycles.
- If a host is blocked, name the blocker owner and the fallback packet.
- If a host has no useful autonomous work, say why; user-attended smoke is the
  only acceptable idle reason.
- Prefer creating a ready packet over letting a host idle behind another host's
  dependency.

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
