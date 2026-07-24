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

## macOS-observed instance (2026-07-23)

Second live observation of THIS race, on a macOS host (the forge runs Linux
inside the Virtualization.framework VM, so the clone below is a genuine
`git://` forge clone, observed from the macOS terminal). Same gate gap — the
forge began cloning before the mirror's objects were clone-reachable — but here
the forge-side backstop retry loop RECOVERED instead of exhausting.

Evidence (forge cloud clone into `/home/forge/src/tillandsias`): the clone was
attempted ~8 times, EACH returning

```text
warning: You appear to have cloned an empty repository
```

then, once the mirror finished receiving/reconciling upstream, the next attempt
succeeded:

```text
remote: Enumerating objects: 54648 ...
Receiving objects: 100% (54648/54648), 98.21 MiB ...
Resolving deltas: 100% (34351/34351), done.
```

So the clone was validated ~8 times BEFORE the mirror was populated — the same
readiness-race this packet describes (Windows saw 12x empty → fail-loud abort;
macOS saw ~8x empty → success). The difference is only where the forge-side
retry budget landed relative to seed completion, not a different defect.

Mechanism confirmed read-only at file:line (Linux/forge-owned):

- The daemon serves clones from the instant it starts, by design — `git daemon
  --export-all` is started FIRST (`images/git/entrypoint.sh:315-323`, order
  437/441 "START THE DAEMON FIRST"), and the empty-mirror seed fetch
  (`git -C "$mirror" fetch origin '+refs/heads/*:refs/heads/*' ...`,
  `images/git/entrypoint.sh:350`) runs AFTERWARD as a background sweep. A clone
  landing in that window gets an empty ref advertisement → empty checkout.
- The launcher readiness gate does NOT close that window because it measures
  local ref PRESENCE, not clone-REACHABILITY over `git://`. `probe_git_mirror_seeded`
  (`crates/tillandsias-headless/src/main.rs:3070-3169`) probes inside the
  container with `git -C /srv/git/<project> rev-parse --quiet --verify HEAD`
  plus `show-ref --verify --quiet refs/heads/<branch>` (or a concrete-head
  `for-each-ref` fallback). It never performs an actual `git://` upload-pack
  clone/`ls-remote` from a client's vantage, so it can pass on the served repo's
  local state while an external `git clone` still transfers an empty tree.
- The residual race is absorbed only by the forge-side backstop:
  `clone_project_from_mirror` (`images/default/lib-common.sh:595-645`) loops
  `git clone git://tillandsias-git/<project>` `max_retries=12` (2s x6, then
  5s x6) and, after each clone, asserts `git -C "$clone_dir" rev-parse --verify
  --quiet HEAD`, wiping+retrying on the empty-repo case (comment at
  `lib-common.sh:599-608`). macOS rode this out at attempt ~9; Windows exhausted
  all 12. This backstop is a fail-loud safety net, not the gate — its budget
  being adequate here does not close the gap.

The gap (unchanged from the root cause above): readiness is gated on
seeded/ref-present-locally, not on objects being clone-reachable over `git://`;
equivalently, the retry-until-reachable behaviour lives only in the forge-side
backstop, whose fixed budget can still exhaust (Windows) even though it
recovered here. A gate that probes readiness the way a client experiences it
(an actual `git://` clone/`ls-remote` returning a non-empty, object-complete
tree) would hold the launch until the seed is genuinely cloneable. This is
Linux/forge-owned (`images/git/` + the launcher gate); the fix lands on
`linux-next`. This section is the macOS-observed capture only — no code changed.
