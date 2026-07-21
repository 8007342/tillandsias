#!/usr/bin/env bash
# @trace spec:git-mirror-service, spec:forge-hot-cold-split, spec:litmus-framework
#
# Fixture for ensure_forge_git_index (order 425).
#
# WHY THIS EXISTS — an absent .git/index is a DATA-LOSS path, not an
# inconvenience. The host-side facade builder cannot run `git read-tree` when
# the launching host has no git binary (WSL2 and VZ guests ship none), so it
# returned early leaving the index absent, with a comment promising
# "in-container materialization" that nothing implemented.
#
# With no index, git reports every tracked file as BOTH staged-deleted and
# untracked, and `git commit -am` — the most ordinary command an agent runs —
# commits the deletion of the entire tree. The working tree still holds every
# file so nothing looks wrong locally, and the mirror relays that commit
# straight to GitHub.
#
# Case 3 is the load-bearing one: it reproduces the mass deletion WITHOUT the
# guard, then proves the guard prevents it. If case 3 cannot fail, this fixture
# is decorative.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/images/default/lib-common.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
trace_lifecycle() { :; }

command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }
[ -r "$LIB" ] || fail "cannot read $LIB"

# Load only the function under test — sourcing all of lib-common.sh would run
# forge-container setup that must not execute on a build host.
eval "$(sed -n '/^ensure_forge_git_index()/,/^}/p' "$LIB")"
command -v ensure_forge_git_index >/dev/null 2>&1 \
    || fail "could not load ensure_forge_git_index from lib-common.sh"

make_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q .
    for f in a b c; do echo "content-$f" > "$d/$f.txt"; done
    git -C "$d" add . >/dev/null
    git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
}

# --- case 1: index present is a no-op ---------------------------------------
R1="$WORK/present"; make_repo "$R1"
ensure_forge_git_index "$R1" || fail "case1: healthy repo must pass"
echo "case 1 ok: existing index untouched"

# --- case 2: absent index is materialised from HEAD -------------------------
R2="$WORK/absent"; make_repo "$R2"
rm -f "$R2/.git/index"
ensure_forge_git_index "$R2" || fail "case2: absent index must be rebuilt, not fail"
[ -e "$R2/.git/index" ] || fail "case2: index was not materialised"
echo "case 2 ok: absent index materialised from HEAD"

# --- case 3: NEGATIVE CONTROL — the mass deletion, with and without the guard
# 3a: WITHOUT the guard, `git commit -am` must empty HEAD. If this stops being
# true the hazard is gone and this fixture should be revisited — but do NOT
# weaken the guard on that basis without re-running this.
R3="$WORK/hazard"; make_repo "$R3"
rm -f "$R3/.git/index"
git -C "$R3" -c user.email=t@t -c user.name=t commit -qam "unguarded" >/dev/null 2>&1
HAZARD_FILES="$(git -C "$R3" ls-tree --name-only HEAD | tr -d '[:space:]')"
[ -z "$HAZARD_FILES" ] \
    || fail "case3a: expected the unguarded commit to empty HEAD (hazard not reproduced); got '$HAZARD_FILES'"

# 3b: WITH the guard, the same sequence preserves the tree.
R4="$WORK/guarded"; make_repo "$R4"
rm -f "$R4/.git/index"
ensure_forge_git_index "$R4" || fail "case3b: guard must succeed"
git -C "$R4" -c user.email=t@t -c user.name=t commit -qam "guarded" >/dev/null 2>&1
GUARDED_FILES="$(git -C "$R4" ls-tree --name-only HEAD | tr '\n' ' ')"
case "$GUARDED_FILES" in
    *a.txt*b.txt*c.txt*) ;;
    *) fail "case3b: guarded commit lost files; HEAD now '$GUARDED_FILES'" ;;
esac
echo "case 3 ok: mass-deletion reproduced WITHOUT the guard, prevented WITH it"

# --- case 4: a non-repo path is a no-op, not an error -----------------------
ensure_forge_git_index "$WORK/not-a-repo-$$" \
    || fail "case4: a non-repo path must be a benign no-op"
echo "case 4 ok: non-repo path is a no-op"

# --- case 5: a repo with no HEAD yet is a no-op -----------------------------
R5="$WORK/nohead"; mkdir -p "$R5"; git -C "$R5" init -q .
ensure_forge_git_index "$R5" || fail "case5: pre-first-commit repo must be a no-op"
echo "case 5 ok: repo without HEAD is a no-op"

echo "PASS: forge git index materialization fixture (order 425)"
