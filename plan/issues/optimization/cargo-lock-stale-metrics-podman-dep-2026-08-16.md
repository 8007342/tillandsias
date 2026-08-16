---
title: Cargo.lock stale at linux-next HEAD — any workspace cargo build dirties the tree
status: open
kind: optimization
filed_at: 2026-08-16T20:27:00Z
filed_by: forge-cycle-2026-08-16T20:24Z
host: forge
active_release: v0.4
scope: one-line lockfile sync; verifiable via cargo build + git status
---

# Cargo.lock stale at linux-next HEAD — 2026-08-16

## Observation

At `linux-next` HEAD `35a8ca02`, `crates/tillandsias-metrics/Cargo.toml` (line
12) declares `tillandsias-podman = { path = "../tillandsias-podman" }`, but the
committed `Cargo.lock` does not list `tillandsias-podman` in the
`tillandsias-metrics` package's `dependencies`. The first workspace `cargo
build` (here: `scripts/cycle-preflight.sh`'s instrument rebuild) therefore
auto-syncs the lockfile, adding exactly that one line and leaving `Cargo.lock`
modified in the worktree.

Consequences:

- Every forge cycle that runs `cycle-preflight.sh` starts with a dirty
  worktree; `scripts/check-opsx-generated-dirt.sh` then reports
  `non-opsx:Cargo.lock` (observed this cycle), so the opsx-only fast path is
  defeated.
- The dirty-start preflight would refuse a cycle that snapshots its boundary
  after preflight unless the lockfile drift is understood.
- Any `cargo build` on a bare-metal host (dev, CI) dirties the tree for the
  same reason.

## Verifiable constraint

On a clean checkout of `linux-next`:

```bash
git status --porcelain | grep -q Cargo.lock && echo "STILL DIRTY" || echo "clean"
cargo build --release -p tillandsias-plan
git status --porcelain   # shows Cargo.lock modified -> drift reproduced
```

## Smallest fix

Commit the one-line lockfile sync (the diff is exactly `"tillandsias-podman",`
inserted into `tillandsias-metrics`'s dependency list; deterministic output of
cargo itself). The fix commit this cycle carries the sync; a follow-up host
should verify with `./build.sh --check` that the synced lock passes the gate
and check whether `./build.sh --check` should use `--locked` (or detect
lockfile drift) so this class fails loud instead of silently dirtying trees.
