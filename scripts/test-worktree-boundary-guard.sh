#!/usr/bin/env bash
# @trace order:717-3bvv, spec:meta-orchestration
set -uo pipefail

# Fixture for the startup-boundary guard's skip detection (order 717-3bvv).
#
# The breach shape: a cycle runs Finalization's `verify` without ever having run
# Start Of Cycle's `snapshot`. Before this packet the guard answered
#
#   error: state directory does not exist: /tmp/meta-orchestration-boundary.Wxg6hS
#
# — the path from the PREVIOUS cycle, already removed on its own exit — so the
# skip read as a stale temp path rather than as a missing guard, and the cycle
# carried on. It must instead name the process fault: `blocked:no-snapshot-taken`.
#
# Everything here runs inside a throwaway git repo under TMPDIR. Nothing touches
# the real checkout, the real stamps, or any remote.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/meta-orchestration-worktree-guard.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/worktree-boundary-guard-fixture.XXXXXX")"
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b work
git -C "$repo" config user.email fixture@example.invalid
git -C "$repo" config user.name fixture
printf 'tracked\n' >"$repo/tracked.txt"
git -C "$repo" add tracked.txt
git -C "$repo" commit -qm "seed"

failures=()

# run <name> <expect-exit> <verdict-substring> -- <guard args...>
run() {
    local name="$1" want_rc="$2" want="$3"; shift 4
    local rc=0 out
    out="$(cd "$repo" && "$GUARD" "$@" 2>&1)" || rc=$?
    if [ "$rc" -ne "$want_rc" ]; then
        failures+=("$name: exit=$rc expected=$want_rc (out: $out)")
    elif ! grep -Fq "$want" <<<"$out"; then
        failures+=("$name: expected '$want', got: $out")
    fi
}

# 1. THE BREACH: verify with no snapshot ever taken, pointed at a path that no
#    longer exists — exactly the previous cycle's already-removed temp dir.
run "no-snapshot-taken" 3 "blocked:no-snapshot-taken" -- \
    verify "$work/meta-orchestration-boundary.Wxg6hS"

# 2. A snapshot WAS taken this cycle, but verify names a different, missing
#    path. That is a different fault from skipping the guard and must not be
#    reported as one.
state="$work/state-a"
(cd "$repo" && "$GUARD" snapshot "$state") || failures+=("snapshot-a: guard refused")
run "boundary-state-missing" 3 "blocked:boundary-state-missing" -- \
    verify "$work/does-not-exist"

# 3. NEGATIVE CONTROL: a cycle that DID snapshot and left the tree as it found
#    it still verifies clean. Without this, the new verdict could degrade into
#    refusing everything and still look like a working guard.
run "clean-verify" 0 "ok: startup worktree boundary preserved" -- verify "$state"

# 4. The stamp records the head that verification observed, which is what
#    mo-full-attest.sh binds the marker to.
stamp="$repo/.git/boundary-verified"
if [ "$(cat "$stamp" 2>/dev/null | tr -d '[:space:]')" != "$(git -C "$repo" rev-parse HEAD)" ]; then
    failures+=("verified-stamp: expected HEAD $(git -C "$repo" rev-parse HEAD), got '$(cat "$stamp" 2>/dev/null)'")
fi

# 5. The guard still catches what it was built to catch: a cycle that modified a
#    path recorded at startup.
printf 'mutated by the cycle\n' >>"$repo/tracked.txt"
run "dirty-exit" 1 "worktree differs from startup boundary" -- verify "$state"
git -C "$repo" checkout -q -- tracked.txt

# 6. EXTENDED CYCLE (order 725-bu54): a cycle that verifies, then does MORE
#    committed work, must be able to verify AGAIN — against the same startup
#    boundary, not a fresh one. Finalization used to remove the state dir on
#    its first completion, so the second attestation found it gone. This is the
#    shape that cost a real marker.
printf 'more cycle work\n' >>"$repo/tracked.txt"
git -C "$repo" add tracked.txt
git -C "$repo" commit -qm "the work the operator asked for after Finalization"
run "extended-cycle-reverifies" 0 "ok: startup worktree boundary preserved" -- verify "$state"
if [ "$(cat "$stamp" 2>/dev/null | tr -d '[:space:]')" != "$(git -C "$repo" rev-parse HEAD)" ]; then
    failures+=("extended-cycle-restamps: the second verification must record the NEW head, or the marker still refuses")
fi

# 7. A fresh snapshot clears the previous verification, so a stale stamp can
#    never satisfy the next cycle's marker.
state_b="$work/state-b"
(cd "$repo" && "$GUARD" snapshot "$state_b") || failures+=("snapshot-b: guard refused")
if [ -e "$stamp" ]; then
    failures+=("stamp-cleared: boundary-verified survived a new snapshot")
fi

# 8. …and that fresh snapshot RETIRES the previous cycle's state dir, which is
#    what lets Finalization stop removing it. Cleanup is owned by the next
#    start, not by an exit that may never come.
if [ -e "$state" ]; then
    failures+=("previous-boundary-retired: $state survived the next cycle's snapshot")
fi

# 9. NEGATIVE CONTROL on that retirement: a stamp pointing somewhere that is
#    NOT a boundary must not become an arbitrary rm -rf. Point the stamp at a
#    directory holding real files and assert it survives.
bystander="$work/not-a-boundary"
mkdir -p "$bystander"
printf 'operator data\n' >"$bystander/precious.txt"
printf '%s\n' "$bystander" >"$repo/.git/boundary-state"
state_c="$work/state-c"
(cd "$repo" && "$GUARD" snapshot "$state_c") || failures+=("snapshot-c: guard refused")
if [ ! -f "$bystander/precious.txt" ]; then
    failures+=("bystander-untouched: snapshot deleted a directory that was not a boundary")
fi

# 10. CONCURRENCY (order 771-wwzi). The packet was filed believing a fork's
#     snapshot had retired the PARENT's boundary. It cannot: stamps live under
#     `git rev-parse --git-dir`, which for a linked worktree is
#     .git/worktrees/<name>, so a worktree only ever retires what ITS OWN stamp
#     names. This pins the isolation so the belief cannot re-form — and so a
#     future change that moves the stamp to the COMMON dir (which would make
#     the reported bug real) fails here instead of in a 3am cycle.
git -C "$repo" worktree add -q "$work/linked" -b linked 2>/dev/null \
    || failures+=("cross-worktree: could not create a linked worktree")
if [ -d "$work/linked" ]; then
    state_main="$work/state-main"
    state_linked="$work/state-linked"
    (cd "$repo" && "$GUARD" snapshot "$state_main") \
        || failures+=("cross-worktree: main snapshot refused")
    (cd "$work/linked" && "$GUARD" snapshot "$state_linked") \
        || failures+=("cross-worktree: linked snapshot refused")
    if [ ! -d "$state_main" ]; then
        failures+=("cross-worktree-isolated: the linked worktree's snapshot retired the main worktree's boundary")
    fi
    if [ ! -d "$state_linked" ]; then
        failures+=("cross-worktree-isolated: the linked worktree's own boundary did not survive")
    fi
    # And the main worktree can still verify against its own boundary.
    run "cross-worktree-main-still-verifies" 0 "ok: startup worktree boundary preserved" -- \
        verify "$state_main"
fi

# 11. SUPERSEDED IS NOT MISSING (order 771-wwzi). Re-snapshotting in the SAME
#     worktree retires the previous boundary by design; a caller still holding
#     the old path must be told THAT, not handed a path it has never seen.
#     Scenario 2 above is the negative control: a path that was never a
#     boundary keeps the boundary-state-missing verdict.
state_super_old="$work/state-super-old"
state_super_new="$work/state-super-new"
(cd "$repo" && "$GUARD" snapshot "$state_super_old") || failures+=("snapshot-super-old: guard refused")
(cd "$repo" && "$GUARD" snapshot "$state_super_new") || failures+=("snapshot-super-new: guard refused")
run "boundary-superseded" 3 "blocked:boundary-superseded" -- verify "$state_super_old"
run "boundary-superseded-names-both" 3 "requested: $state_super_old" -- verify "$state_super_old"

if [ "${#failures[@]}" -gt 0 ]; then
    printf 'FAIL: %s\n' "${failures[@]}" >&2
    echo "boundary-guard: FAIL ${#failures[@]} scenario(s) did not match expected verdicts"
    exit 1
fi
echo "PASS: worktree-boundary-guard fixture 12/12 scenarios green (no-snapshot-taken, boundary-state-missing, clean-verify, verified-stamp, dirty-exit, extended-cycle-reverifies, stamp-cleared, previous-boundary-retired, bystander-untouched, cross-worktree-isolated, cross-worktree-main-still-verifies, boundary-superseded)"
