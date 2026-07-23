# Mirror readiness gate passes on reachable, not seeded — clone races seed

**Filed**: 2026-07-23T02:20Z
**Host**: forge (TILLANDSIAS_HOST_KIND=forge)
**Classification**: bugfix
**Status**: implementation complete — live pristine/reattach verification pending
**Order**: mirror-first-seed-vs-launch-readiness-race (provisional)

## Symptom

Operator's first Windows forge attach (fresh guest, first launch): cloud clone
succeeded, missing images built, then the forge's bounded in-container clone got
"empty repository" 12x and fail-loud aborted. Volume autopsy: the mirror's
initial upstream fetch completed ~14 minutes AFTER the readiness gate passed.

## Root cause

`wait_for_git_mirror_ready` originally checked only `git rev-parse --verify
HEAD`. After `ensure-mirror-head` symlinks HEAD to a ref, this can pass while the
upstream seed fetch is still in progress. Commit `dec1175e` added a second probe
but hard-coded `refs/heads/main`, contradicting the convention-neutral mirror
contract for projects whose branch is `master`, `trunk`, or another name. Its
comment also promised a backward-compatible HEAD fallback that the control flow
never returned.

## Fix

The bounded readiness gate now requires:

1. `git rev-parse --verify HEAD` (catches an unborn HEAD), and
2. when the launcher knows the host checkout branch, `git show-ref --verify
   --quiet refs/heads/<branch>`; otherwise, a non-empty `git for-each-ref
   --count=1 --format=%(objectname) refs/heads`.

This keeps the target-project branch convention authoritative while preserving
the detached/git-less fallback. A named 20-minute cold-seed bound exceeds the
live Windows 12–15 minute observation with room for proxy/cache variance. The
attempt-5 progress notice and timeout refusal remain, while a seeded mirror
still returns on its first two probes without sleeping.

**Changed**: `crates/tillandsias-headless/src/main.rs` — the launcher threads
`project_default_branch` into `wait_for_git_mirror_ready`; a one-attempt probe
seam makes both sides of the race deterministic under the fake Podman backend.

## Verification

- `cargo test -p tillandsias-headless git_mirror_readiness -- --nocapture` →
  4 passed (non-main `trunk` fast path, reachable-but-unseeded refusal,
  metadata-free concrete-head fallback, and the 20-minute bound).
- `cargo test -p tillandsias-headless` → 241 passed, 1 ignored.
- `cargo fmt --all -- --check` → passed.
- `cargo run -q -p tillandsias-policy -- validate-yaml plan/index.yaml` →
  passed.
- `./build.sh --check` → passed.
- `scripts/e2e-preflight.sh eligibility` → `skip:no-podman-binary`.

## Remaining live evidence

This forge cannot run Podman, so source/unit evidence does not close the packet.
On a mutable Podman or Windows smoke host:

1. build a revision containing this checkpoint and remove the target project's
   mirror volume;
2. first-launch a project whose working/default branch is not `main`, record the
   bounded visible seed wait, and confirm the forge lands on a populated
   checkout with no empty-clone abort;
3. re-attach against the seeded volume and record the first-probe fast path.
