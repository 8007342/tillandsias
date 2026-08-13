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
    elif ! printf '%s' "$out" | grep -Fq "$want"; then
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

# 6. A fresh snapshot clears the previous verification, so a stale stamp can
#    never satisfy the next cycle's marker.
state_b="$work/state-b"
(cd "$repo" && "$GUARD" snapshot "$state_b") || failures+=("snapshot-b: guard refused")
if [ -e "$stamp" ]; then
    failures+=("stamp-cleared: boundary-verified survived a new snapshot")
fi

if [ "${#failures[@]}" -gt 0 ]; then
    printf 'FAIL: %s\n' "${failures[@]}" >&2
    echo "boundary-guard: FAIL ${#failures[@]} scenario(s) did not match expected verdicts"
    exit 1
fi
echo "PASS: worktree-boundary-guard fixture 6/6 scenarios green (no-snapshot-taken, boundary-state-missing, clean-verify, verified-stamp, dirty-exit, stamp-cleared)"
