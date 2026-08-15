#!/usr/bin/env bash
# @trace spec:methodology-accountability
# @trace order:723-b9cn
#
# Fixture for the DEFAULT SCOPE of scripts/check-version-bump-isolation.sh.
#
# THE BUG THIS EXISTS TO PREVENT (measured live on osx-next 2026-08-13): the
# guard's default range was `@{upstream}..HEAD`. A platform branch must merge
# origin/linux-next before every push (methodology pull_merge_cadence
# .pre_push_gate) while its own remote head lags, so that range swept in every
# commit the integration branch had published in the meantime — 89 non-merge
# commits, two of which it flagged: bad35b4928c8 (windows) and dd8fd63fac57
# (linux). Both were already immutable on origin/linux-next. This host could
# neither fix nor drop them, so the MANDATED merge produced a permanently
# unpushable branch whose only exit was `--no-verify` — which also disables the
# local gate that replaced push CI.
#
# The rule: a branch is answerable for what it AUTHORS, not for what it ACCEPTS
# from the host that owns it. A commit reachable from an origin remote-tracking
# ref was already gate-checked at its own first push.
#
# CASE 2 IS THE LOAD-BEARING ONE. "Scope to unpublished commits" is trivially
# satisfiable by "check nothing at all", and case 1 alone cannot tell those
# apart — it passes for both. Case 2 is what makes the narrowing falsifiable.
#
# Hermetic: builds a throwaway repo with a real refs/remotes/origin ref; touches
# nothing outside its temp dir.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-version-bump-isolation.sh"
WORK="$(mktemp -d)"
FAILURES=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok() { echo "ok: $*"; }

[ -r "$GUARD" ] || { echo "FAIL: guard not readable: $GUARD" >&2; exit 1; }

REPO="$WORK/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init -q -b main
git config user.email fixture@example.invalid
git config user.name fixture

printf 'v1\n' > VERSION
printf 'x\n' > Cargo.toml
git add -A
git commit -qm "base"

# THIS BRANCH'S OWN REMOTE HEAD, DELIBERATELY LAGGING, plus an upstream tracking
# it. That is the production shape: osx-next's remote sat 109 commits back while
# the branch carried the integration history it was required to merge. Without
# the upstream the old guard takes its "no upstream -> no-op" path and case 1
# below cannot discriminate, because a guard that checks nothing also passes it.
git remote add origin https://example.invalid/repo.git
git update-ref refs/remotes/origin/platform HEAD
git branch -q --set-upstream-to=origin/platform \
    || fail "precondition: could not set a lagging upstream (git refuses without remote.origin)"

# --- a SWEEP authored by "another host", already published -------------------
# VERSION moved together with an unrelated source file: exactly the shape the
# guard refuses. Then it is published, i.e. made reachable from a remote ref.
printf 'v2\n' > VERSION
mkdir -p src
printf 'code\n' > src/main.rs
git add -A
git commit -qm "sweep authored elsewhere"
FOREIGN="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/linux-next "$FOREIGN"
git update-ref refs/remotes/origin/main "$FOREIGN"

# Sanity: the guard must still SEE this as a sweep when asked directly.
# Without this, case 1 could pass because the commit is not a sweep at all.
if bash "$GUARD" --commit "$FOREIGN" >/dev/null 2>&1; then
    fail "precondition: the fixture's 'foreign' commit is not actually a sweep"
else
    ok "precondition — the published commit IS a sweep when asked explicitly"
fi

# --- case 1: a PUBLISHED sweep must NOT be re-policed by default -------------
out="$(bash "$GUARD" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    fail "a sweep already published on origin was refused by the default range (rc=$rc) — the mandated merge makes the branch unpushable: $out"
else
    ok "published sweep not re-policed by default (rc=0)"
fi

# --- case 2 (LOAD-BEARING): a LOCAL sweep must STILL be refused --------------
# Not reachable from any remote ref, so this branch is publishing it for the
# first time and owns it. If the narrowing above degenerated into "check
# nothing", this case fails.
printf 'v3\n' > VERSION
printf 'more\n' > src/main.rs
git add -A
git commit -qm "sweep authored HERE, unpublished"
LOCAL="$(git rev-parse HEAD)"
out="$(bash "$GUARD" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
    fail "a locally-authored, unpublished sweep was ALLOWED (rc=0) — the scope narrowing has repealed the guard instead of narrowing it"
else
    case "$out" in
        *"${LOCAL:0:12}"*) ok "locally-authored sweep still refused, naming the commit (rc=$rc)" ;;
        *) fail "local sweep refused (rc=$rc) but the output does not name ${LOCAL:0:12}: $out" ;;
    esac
fi

# --- case 3: a clean local release bump must PASS ----------------------------
# VERSION + companion files only. Without this, "refuse every local commit
# touching VERSION" would satisfy case 2 and make a real release impossible.
git checkout -q -b release/version-bump-test "$FOREIGN"
printf 'v9\n' > VERSION
printf 'y\n' > Cargo.toml
git add -A
git commit -qm "clean release bump"
out="$(bash "$GUARD" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    fail "a clean VERSION+Cargo.toml bump was refused (rc=$rc) — releases become impossible: $out"
else
    ok "clean local release bump allowed (rc=0)"
fi

# --- case 4: a MERGE inheriting a foreign VERSION is exempt ------------------
# The 643-64bx catch-up shape, at the commit level.
git checkout -q -b platform "$(git rev-list --max-parents=0 HEAD)"
printf 'work\n' > platform.txt
git add -A
git commit -qm "platform work"
git merge -q --no-ff --no-edit "$FOREIGN" -m "merge: integration catch-up" 2>/dev/null
out="$(bash "$GUARD" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    fail "a merge inheriting a foreign VERSION was refused (rc=$rc): $out"
else
    ok "merge inheriting a foreign VERSION exempt (rc=0)"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "PASS: version-bump-isolation scope 5/5"
    exit 0
fi
echo "FAILED: $FAILURES case(s)" >&2
exit 1
