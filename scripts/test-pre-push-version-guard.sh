#!/usr/bin/env bash
# @trace spec:versioning
#
# Hermetic fixture for scripts/hooks/pre-push-version-guard.sh (order 643-64bx).
#
# The guard is load-bearing: main's VERSION is the release identity and a
# platform branch must not move it. It is also the guard that deadlocked a
# release on 2026-08-04 and a windows-next push on 2026-08-13, and a guard that
# must be bypassed trains `--no-verify`, which also disables the local gate that
# replaced push CI. So both directions need pinning, and the NEGATIVE CONTROL is
# the load-bearing case: if a platform branch could push a VERSION of its own
# invention, the exception added for integration catch-up would have quietly
# repealed the guard instead of narrowing it.
#
# Builds a throwaway repo with the real three-tier topology. Branch names
# containing a slash are legal refs, so `origin/main` and `origin/linux-next`
# resolve exactly as the guard expects without a remote.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/hooks/pre-push-version-guard.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$GUARD" ] || fail "guard not found: $GUARD"

cd "$WORK"
git init -q .
git config user.email fixture@example.invalid
git config user.name Fixture
git symbolic-ref HEAD refs/heads/main

echo "56.9.10.1" > VERSION
echo seed > file.txt
git add -A
git commit -qm "seed at release identity"
MAIN_SHA="$(git rev-parse HEAD)"
git branch "origin/main" "$MAIN_SHA"

# linux-next runs ahead of main between releases — the documented normal state.
git checkout -q -b "origin/linux-next" "$MAIN_SHA"
echo "56.9.12.1" > VERSION
git commit -qam "linux-next build counter"
INTEGRATION_SHA="$(git rev-parse HEAD)"

# The push git would describe: "<lref> <lsha> <rref> <rsha>" on stdin.
run_guard() { # <branch> <remote-sha> <local-sha>
    git checkout -q "$1"
    printf 'refs/heads/%s %s refs/heads/%s %s\n' "$1" "$3" "$1" "$2" \
        | bash "$GUARD" origin https://example.invalid/repo.git >/dev/null 2>&1
}

# --- case 1: a platform branch that merged linux-next may push ---------------
# It carries a VERSION it did not choose. Refusing this makes the merge the
# pre-push gate REQUIRES produce a permanently unpushable branch.
git checkout -q -b windows-next "$MAIN_SHA"
echo work > platform.txt
git add -A
git commit -qm "platform work"
git merge -q --no-edit "origin/linux-next"
CATCHUP_SHA="$(git rev-parse HEAD)"
if ! run_guard windows-next "$MAIN_SHA" "$CATCHUP_SHA"; then
    fail "case 1: integration catch-up must be allowed (VERSION equals origin/linux-next)"
fi
echo "ok: case 1 — platform branch carrying linux-next's VERSION pushes"

# --- case 2: a platform branch's OWN strictly-greater bump, committed alone -
# RETIRED NEGATIVE CONTROL, kept here with its disproof. Until 2026-09-17 this
# case asserted REFUSAL ("a platform host does not own the release"). The
# operator's ruling that day made the local build counter a monotonic
# YEAR_FROM_EPOCH.MONTH.DAY.BUILD counter that increments freely on any branch
# (order 643-64bx exception 5), so a well-formed, strictly-greater, isolated
# bump now PUSHES. The refusals that replace it are cases 5-9.
echo "56.9.12.2" > VERSION
git commit -qam "platform-local counter bump, alone"
OWN_SHA="$(git rev-parse HEAD)"
if ! run_guard windows-next "$MAIN_SHA" "$OWN_SHA"; then
    fail "case 2: a well-formed, strictly-greater bump committed alone must push (643-64bx)"
fi
echo "ok: case 2 — a monotonic build bump committed alone pushes"

# --- case 3: commits that do not touch VERSION are none of the guard's business
git checkout -q -B windows-next "$CATCHUP_SHA"
echo more >> platform.txt
git commit -qam "ordinary work, VERSION untouched"
PLAIN_SHA="$(git rev-parse HEAD)"
if ! run_guard windows-next "$CATCHUP_SHA" "$PLAIN_SHA"; then
    fail "case 3: a range that does not change VERSION must be allowed"
fi
echo "ok: case 3 — range not touching VERSION pushes"

# --- case 4: main may move the release identity ------------------------------
git checkout -q -B main "$MAIN_SHA"
echo "56.9.13.1" > VERSION
git commit -qam "release bump on main"
if ! run_guard main "$MAIN_SHA" "$(git rev-parse HEAD)"; then
    fail "case 4: main is where a release bump lands"
fi
echo "ok: case 4 — release bump on main allowed"

# --- cases 5-9: what exception 5 must still refuse --------------------------
# Each starts from the catch-up branch (VERSION == linux-next's 56.9.12.1).
refuse() { # <case> <why> <sha> [remote-sha]
    if run_guard windows-next "${4:-$CATCHUP_SHA}" "$3"; then fail "case $1: $2 must be refused"; fi
    echo "ok: case $1 — $2 refused"
}
git checkout -q -B windows-next "$CATCHUP_SHA"
echo "56.9.11.9" > VERSION; git commit -qam "lower than linux-next"
refuse 5 "a bump LOWER than linux-next" "$(git rev-parse HEAD)"

# 6 (NEGATIVE CONTROL): NON-MONOTONIC against the TARGET. windows-next already
# carries its own earlier bump 56.9.12.5; a push that moves it to 56.9.12.4 is
# above linux-next (56.9.12.1) yet goes BACKWARDS on the branch it lands on.
# The pre-643-64bx guard refused it too (a VERSION matching no catch-up
# source), so this refusal is unchanged. "Equal" has no separate arm: a range
# ending on the target's own value is no net VERSION change (case 3), and one
# ending on linux-next's, main's or a tag's is a catch-up (case 1).
git checkout -q -B windows-next "$CATCHUP_SHA"
echo "56.9.12.5" > VERSION; git commit -qam "target's earlier bump"; PRIOR_SHA="$(git rev-parse HEAD)"
echo "56.9.12.4" > VERSION; git commit -qam "backwards on the target"
refuse 6 "a bump BELOW the target's previous VERSION (non-monotonic)" "$(git rev-parse HEAD)" "$PRIOR_SHA"

git checkout -q -B windows-next "$CATCHUP_SHA"
echo "56.13.12.2" > VERSION; git commit -qam "month 13"
refuse 7 "a MALFORMED VERSION (month 13)" "$(git rev-parse HEAD)"
git checkout -q -B windows-next "$CATCHUP_SHA"
echo "0.4.260812.2" > VERSION; git commit -qam "legacy shape"
refuse 8 "a MALFORMED VERSION (legacy 0.4.YYMMDD.N shape)" "$(git rev-parse HEAD)"

git checkout -q -B windows-next "$CATCHUP_SHA"
echo "56.9.12.2" > VERSION; echo swept >> platform.txt
git commit -qam "bump swept in with work"
refuse 9 "a MIXED-CONTENT bump (VERSION + unrelated file, 702-eusw)" "$(git rev-parse HEAD)"

echo "PASS: pre-push VERSION guard (9/9)"
