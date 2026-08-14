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

echo "0.4.260810.1" > VERSION
echo seed > file.txt
git add -A
git commit -qm "seed at release identity"
MAIN_SHA="$(git rev-parse HEAD)"
git branch "origin/main" "$MAIN_SHA"

# linux-next runs ahead of main between releases — the documented normal state.
git checkout -q -b "origin/linux-next" "$MAIN_SHA"
echo "0.4.260812.1" > VERSION
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

# --- case 2 (NEGATIVE CONTROL): a VERSION of the branch's own invention ------
# Ahead of BOTH main and linux-next. A platform host does not own the release,
# so this must still be refused — otherwise case 1's exception repealed the
# guard rather than narrowing it.
echo "0.4.260812.2" > VERSION
git commit -qam "platform-local counter bump"
OWN_SHA="$(git rev-parse HEAD)"
if run_guard windows-next "$MAIN_SHA" "$OWN_SHA"; then
    fail "case 2: a divergent bump ahead of main AND linux-next must be refused"
fi
echo "ok: case 2 — divergent platform-local bump still refused"

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
echo "0.4.260813.1" > VERSION
git commit -qam "release bump on main"
if ! run_guard main "$MAIN_SHA" "$(git rev-parse HEAD)"; then
    fail "case 4: main is where a release bump lands"
fi
echo "ok: case 4 — release bump on main allowed"

echo "PASS: pre-push VERSION guard (4/4)"
