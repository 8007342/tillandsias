#!/usr/bin/env bash
# @trace spec:methodology-accountability
# @trace order:702-pwhc
#
# Fixture for scripts/hooks/pre-push-version-guard.sh.
#
# THE BUG THIS EXISTS TO PREVENT (measured live 2026-08-13): the guard decided
# "does this push change VERSION?" with
#
#     git diff --name-only "$r" | grep -qx "VERSION"
#
# under `set -o pipefail`. `grep -q` exits the instant it matches, git dies of
# SIGPIPE and reports 141, and pipefail promotes that to the pipeline status —
# so the `if` read FALSE *because* the match was found early. The guard failed
# OPEN, and it did so as a function of DIFF SIZE: a 64-file range was refused
# correctly while a 445-file range sailed through with the identical VERSION
# divergence in it. That is backwards from what a release guard is for; large
# cross-branch merges are the only way a foreign VERSION arrives at all.
#
# THE LOAD-BEARING CASE BELOW IS THEREFORE THE LARGE ONE. A fixture that only
# exercised a small diff would have passed against the broken guard and
# certified it as working — which is how the defect survived in the first
# place. The size threshold is not fixed (it depends on pipe buffer and
# scheduling), so the large case uses enough files to exceed any plausible
# 64 KiB pipe buffer by a wide margin.
#
# Hermetic: builds a throwaway repo in a temp dir; touches nothing real.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/hooks/pre-push-version-guard.sh"
WORK="$(mktemp -d)"
FAILURES=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok() { echo "ok: $*"; }

[ -r "$GUARD" ] || { echo "FAIL: guard not readable: $GUARD" >&2; exit 1; }

# Path length matters more than file COUNT. The race needs `git diff` to still
# be walking when grep exits, and `VERSION` sorts FIRST in the output (ASCII
# uppercase precedes lowercase), so grep matches on line 1 every time.
# Calibrated 2026-08-13: ~12 KB of output did NOT reproduce; 28 KB did, as did
# the 23 KB real-world case. These names put the fixture near 120 KB.
FILLER_NAME="some-reasonably-long-filename-to-pad-the-diff-output"

# --- build a throwaway repo with a `main` carrying VERSION -------------------
REPO="$WORK/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init -q -b main
git config user.email fixture@example.test
git config user.name fixture
echo "0.0.0.1" > VERSION
git add VERSION
git commit -qm "base: VERSION 0.0.0.1"
BASE="$(git rev-parse HEAD)"

# A local "origin/main" so the guard's `git show origin/main:VERSION` resolves
# without a network remote.
git update-ref refs/remotes/origin/main "$BASE"

# --- branch that bumps VERSION *and* touches many other files ---------------
git checkout -q -b work
echo "0.0.0.2" > VERSION
mkdir -p many
i=0
while [ "$i" -lt 2000 ]; do
    printf 'filler %s\n' "$i" > "many/$FILLER_NAME-$i.txt"
    i=$((i + 1))
done
git add -A
git commit -qm "bump VERSION and touch 600 files"
BIG="$(git rev-parse HEAD)"

run_guard() { # <local-sha> <remote-sha>
    printf 'refs/heads/work %s refs/heads/target %s\n' "$1" "$2" \
        | bash "$GUARD" origin https://example.test/repo.git >/dev/null 2>&1
    echo $?
}

file_count="$(git diff --name-only "$BASE..$BIG" | wc -l | tr -d ' ')"
[ "$file_count" -gt 500 ] || fail "fixture too small to exercise the SIGPIPE path ($file_count files)"

# --- case 1 (LOAD-BEARING): large VERSION-changing range must be REFUSED ----
rc="$(run_guard "$BIG" "$BASE")"
if [ "$rc" -eq 0 ]; then
    fail "large range ($file_count files) changing VERSION was ALLOWED (rc=0) — the guard is failing open, exactly the 702-pwhc SIGPIPE defect"
else
    ok "large range ($file_count files) changing VERSION refused (rc=$rc)"
fi

# --- case 2: same thing as a NEW remote branch (all-zero remote sha) --------
rc="$(run_guard "$BIG" "0000000000000000000000000000000000000000")"
if [ "$rc" -eq 0 ]; then
    fail "large range to a NEW branch changing VERSION was ALLOWED (rc=0)"
else
    ok "large range to a new branch changing VERSION refused (rc=$rc)"
fi

# --- case 3 (NEGATIVE CONTROL): a range that does NOT touch VERSION ---------
# Without this, "refuse everything" would pass cases 1 and 2 and would be a
# strictly worse guard than none — it would train --no-verify, which also
# disables the local build gate.
git checkout -q -b no-version-change "$BASE"
echo "unrelated" > unrelated.txt
git add unrelated.txt
git commit -qm "change nothing that matters"
CLEAN="$(git rev-parse HEAD)"
printf 'refs/heads/no-version-change %s refs/heads/target %s\n' "$CLEAN" "$BASE" \
    | bash "$GUARD" origin https://example.test/repo.git >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    fail "a push that does NOT change VERSION was refused (rc=$rc) — guard must not block ordinary work"
else
    ok "push not touching VERSION allowed (rc=0)"
fi

# --- case 4: sync-forward (VERSION equal to main's) must be ALLOWED ---------
git checkout -q -b sync-forward "$BASE"
mkdir -p many2
i=0
while [ "$i" -lt 2000 ]; do
    printf 'filler %s\n' "$i" > "many2/$FILLER_NAME-$i.txt"
    i=$((i + 1))
done
echo "0.0.0.9" > VERSION
git add -A
git commit -qm "diverge VERSION"
echo "0.0.0.1" > VERSION          # back to main's value: a catch-up, not a bump
git add VERSION
git commit -qm "sync forward to main's VERSION"
SYNC="$(git rev-parse HEAD)"
printf 'refs/heads/sync-forward %s refs/heads/target %s\n' "$SYNC" "$BASE" \
    | bash "$GUARD" origin https://example.test/repo.git >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
    fail "sync-forward (VERSION == main's) was refused (rc=$rc) — this is the documented legitimate case"
else
    ok "sync-forward allowed (rc=0)"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "PASS: pre-push-version-guard 4/4"
    exit 0
fi
echo "FAILED: $FAILURES case(s)" >&2
exit 1
