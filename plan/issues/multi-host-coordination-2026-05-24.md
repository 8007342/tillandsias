# Multi-Host Coordination - 2026-05-24

## Status

Active. This issue is the repo-local coordination record for concurrent Linux,
Windows, and macOS host work.

## Context

Claudia aligned these remote branches to the Phase 6 Vault tip `ddf52dff`:

- `origin/linux-next`
- `origin/windows-next`
- `origin/osx-next`
- `origin/main`

The branches were pure ancestors of the shared tip at the time of alignment, so
the fast-forwards did not discard platform work. Future hosts may advance their
platform branch independently, so every session must re-check current remote
state.

## Branch Convention

- Linux host checkpoints to `linux-next`.
- Windows host checkpoints to `windows-next`.
- macOS host checkpoints to `osx-next`.
- Shared, stable, cross-cutting work lands on `main` or the declared shared
  integration source, then fast-forwards to platform branches only after an
  ancestry check.
- Platform-specific tray wrapper work stays on the owning platform branch until
  stable enough to merge back.
- Shared protocol and orchestration stay in `crates/tillandsias-host-shell`,
  `crates/tillandsias-core`, and `crates/tillandsias-headless`.

## Required Start-of-Session Checks

```bash
git fetch origin
git pull --ff-only
git ls-remote origin refs/heads/main refs/heads/linux-next refs/heads/windows-next refs/heads/osx-next
git status --short --branch
```

Record observed sibling heads in the active step or issue before editing shared
files.

## Fast-Forward Guard

Before fast-forwarding a remote platform branch from a shared source:

```bash
git merge-base --is-ancestor origin/<platform-branch> <source-ref>
```

If the ancestry check fails, stop. Another host has independent work. Create or
update a plan issue with the conflicting branch heads and coordinate explicitly
before pushing.

## Plan Ledger Rules

- Include `host_id`, `platform`, `branch`, `upstream_commit`, and
  `observed_sibling_heads` in cross-host handoffs.
- Update existing stable graph nodes instead of duplicating work by host.
- Treat `plan.yaml`, `plan/index.yaml`, `plan/steps`, and `plan/issues` as the
  durable ledger.
- Use `plan/localwork` only for disposable scratch.
- Never delete another host's note to resolve a conflict; tombstone, supersede,
  or merge by stable ID.

## Current Handoff

The methodology and plan have been updated to make the workflow durable:

- `methodology/multi-host-development.yaml`
- `methodology/between-commits-work-discipline.yaml`
- `methodology/agent-observability.yaml`
- `methodology/event/030-multi-host-branch-coordination.yaml`
- `plan/steps/20-recent-work-spec-doc-methodology-audit.md`

Next agents should adopt this as the first coordination step before resuming
platform implementation.

## Coordination Audit - 2026-05-25T17:10Z

host_id: linux-tlatoani-fedora · platform: linux · branch: linux-next

Observed remote heads at audit start:

- `main`: ddf52dff
- `linux-next`: 201c76ea
- `windows-next`: d3d4cede
- `osx-next`: 201c76ea

Ledger corrections made in this audit:

- `methodology/distributed-work.yaml` now defines explicit status transitions,
  stale/stalled handling, ping rules, prioritization, and completion hygiene.
- `plan/issues/windows-next-work-queue-2026-05-25.md` now marks w1, w2, and
  w3 as `done` in the item headers, matching their terminal events. Windows has
  no cleanly unblocked tray item left; w4/w5/w6 are gated.
- `plan/issues/osx-next-work-queue-2026-05-25.md` now marks m1, m2, and m3 as
  `done` in the item headers and mirrors m1b as the next `ready` macOS item.
- `plan.yaml` and `plan/index.yaml` now describe step 21 as active/in-progress
  rather than ready-but-unclaimed.

Current cross-host gates:

- Linux l7 `§3-materializer-driver` is claimed by Linux and blocks Windows w5
  plus macOS m5.
- Linux l3 `in-vm-headless-pty-handler` blocks Windows w4 and macOS m4.
- Linux l4 `replace-vsock-stub-handlers` blocks Windows w6 verification.
- macOS-owned l5 `recipe-smoke-ci-publish` / CI-fetch work blocks the final
  recipe artifact path after l7 lands.
- macOS m1b `transport-macos-vsock-connector` is ready and should be claimed
  by the macOS host before m4/m5 end-to-end work.

Next audit action:

- If l7 has not produced a checkpoint by the next integration cycle, append a
  ping to `plan/issues/cross-host-blocker-roundup-2026-05-25.md` with the
  last known lease and the smallest reclaimable scope.
