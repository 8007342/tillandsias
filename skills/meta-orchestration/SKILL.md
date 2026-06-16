---
name: meta-orchestration
description: "Host-aware Tillandsias recurring runtime loop: sync remote state, drain claimable plan work, run eligible e2e smoke gates, coordinate integrations on mutable Linux, release when warranted, update plan, commit, and push before exit."
---

# Meta Orchestration

This is the top-level unattended loop intended for:

```bash
./repeat --prompt "Use the /meta-orchestration skill"
```

It composes the worker, coordination, e2e, and release skills without replacing
their detailed runbooks.

## Non-Negotiable Exit Contract

Local state is volatile. Before a successful exit, every meaningful result must
be committed and pushed to the correct remote branch.

- No uncommitted tracked changes.
- No local-only commits.
- No completed work without a `plan/` event or finding.
- No e2e pass/fail without a dated plan report.
- No blocked state without a blocker, owner if known, and smallest next action.

If a push fails after three fetch/rebase retries, mark the active plan item
`blocked` or `failed-retryable`, include the failed push output, and stop.

## Host Classification

Detect host at the start of every cycle:

- `linux_immutable`: Linux with `/run/ostree-booted` present or `rpm-ostree` on PATH.
- `linux_mutable`: Linux without the immutable marker.
- `macos`: Darwin.
- `windows`: Windows, MSYS, MINGW, or PowerShell host.

Canonical branches:

- Linux shared/integration: `linux-next`
- macOS code: `osx-next`
- Windows code: `windows-next`
- Release: `main` through PR only

All `plan/`, `methodology/`, `openspec/`, and `cheatsheets/` writes go to
`linux-next`.

## Start Of Cycle

1. Record UTC time, host kind, current branch, worktree path, and sibling heads.
2. `git fetch origin --prune`.
3. If the worktree is dirty at startup, classify it:
   - tracked changes: commit a checkpoint or block before doing new work;
   - untracked generated artifacts: ignore only if covered by `.gitignore`;
   - unknown user work: do not overwrite it; record a blocker.
4. Update the active local branch from remote with fast-forward or an explicit
   merge from `origin/linux-next` into the platform branch when appropriate.

## Worker Drain

Run `/advance-work-from-plan` in fresh cycles until one of these is true:

- no eligible ready work remains for this host;
- every eligible item is blocked;
- a terminal failure was filed;
- the current cycle has already produced a coherent commit and the next packet
  would exceed the recurring-loop budget.

Each worker cycle must obey the non-negotiable exit contract above.

## E2E Gates

Run eligible e2e gates after worker drain:

| Host kind | Local-build e2e | Curl-install e2e |
|---|---:|---:|
| linux_immutable | no | yes |
| linux_mutable | yes | yes |
| macos | yes | yes |
| windows | yes | yes |

Rules:

- Local-build e2e uses `/build-install-and-smoke-test-e2e`.
- Published-release e2e uses `/smoke-curl-install-and-test-e2e`.
- Destructive substrate reset is expected setup on Tillandsias smoke hosts.
  `podman system reset --force` is a precondition for Linux idempotence tests,
  not a blocker. Do not pause, ask for confirmation, or skip the e2e gate for
  fear of wiping Podman when `TILLANDSIAS_DESTRUCTIVE_RESET_OK` is unset or `1`.
  Only treat reset as blocked when the environment explicitly sets
  `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0`.
- If the plan records a latest tested release older than the current GitHub
  release, prioritize curl-install e2e.
- File every finding as a plan packet; write a PASS report for clean runs.

## Mutable Linux Coordinator Duties

Only `linux_mutable` performs global coordination:

1. Run `/multihost-orchestration` after worker drain or when sibling branches
   advanced.
2. Merge eligible `origin/windows-next` and `origin/osx-next` work into
   `linux-next`, with explicit conflict mediation if needed.
3. Run more frequent local-build e2e gates than other hosts.
4. Run `/merge-to-main-and-release` only when `linux-next` is green, plan
   evidence is current, and no release is already in flight.
5. After a release succeeds, ensure the plan records the new latest release so
   immutable Linux hosts know to run curl-install e2e.

## Finalization

Before exit:

1. Refresh `plan/issues/ACTIVE.md` and `plan/loop_status.md` if this cycle
   changed active work, blockers, tested release, or host assignments.
2. Validate touched YAML with a parser.
3. Commit targeted files only.
4. Push the relevant branch.
5. Confirm `git status --short --branch` is clean and not ahead of upstream.
