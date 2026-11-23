#!/usr/bin/env bash
# @trace order:2224-gdir
#
# test-fixtures-ignore-inherited-git-dir.sh — a fixture run from a hook must
# never write the repository named by an inherited GIT_DIR.
#
# Git exports GIT_DIR to every hook. The pre-push hook runs the preflight door,
# the door runs fixtures, and test-check-credential-channel.sh's
# `git -C <scratch> remote set-url ...` followed GIT_DIR to the real checkout:
# on calmecacpilli 2026-11-22 the real origin became $W/does-not-exist.git and
# credential.helper became manager.
#
#   1 FIXTURE  with GIT_DIR naming a victim repo, test-check-credential-channel.sh
#              leaves the victim's origin and local config unchanged.
#   2 DOOR     build.sh unsets GIT_DIR (and its siblings) before the toolbox
#              re-exec, so no hook-launched guard or fixture inherits it.
#   3 MUTANT   the same run with the fixture's unset removed DOES rewrite the
#              victim (proves arm 1 can fail).
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX="$ROOT/scripts/test-check-credential-channel.sh"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

_tb="$ROOT/target/plan-scratch"; mkdir -p "$_tb" 2>/dev/null || _tb="${TMPDIR:-/tmp}"
W="$(mktemp -d "$_tb/inherited-git-dir.XXXXXX")" || exit 3
trap 'rm -rf "$W"' EXIT

victim() { # victim <name> -> path of a fresh repo with a known origin
    git init -q "$W/$1" && git -C "$W/$1" remote add origin https://example.invalid/victim.git
    printf '%s' "$W/$1"
}
state() { printf '%s|%s' "$(git -C "$1" remote get-url origin 2>&1)" "$(git -C "$1" config --local --list 2>&1 | grep -cE 'credential|hooksPath')"; }

# 1
V="$(victim one)"; before="$(state "$V")"
GIT_DIR="$V/.git" bash "$FX" >/dev/null 2>&1
after="$(state "$V")"
[ "$before" = "$after" ] && ok "1 FIXTURE an inherited GIT_DIR's repo is untouched ($after)" \
    || bad "1 FIXTURE the victim changed: before=[$before] after=[$after]"

# 2
if head -n 80 "$ROOT/build.sh" | grep -q '^unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE'; then
    ok "2 DOOR build.sh clears GIT_DIR and its siblings before the toolbox re-exec"
else
    bad "2 DOOR build.sh no longer clears GIT_DIR in its first 80 lines"
fi

# 3
grep -v '^unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE' "$FX" > "$ROOT/scripts/.mutant-gitdir-2224.sh"
V="$(victim three)"; before="$(state "$V")"
GIT_DIR="$V/.git" bash "$ROOT/scripts/.mutant-gitdir-2224.sh" >/dev/null 2>&1
after="$(state "$V")"
rm -f "$ROOT/scripts/.mutant-gitdir-2224.sh"
[ "$before" != "$after" ] && ok "3 MUTANT without the unset the victim IS rewritten ($after) — arm 1 has teeth" \
    || bad "3 MUTANT without the unset the victim was still untouched — arm 1 proves nothing"

echo "fixtures-ignore-inherited-git-dir: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && { echo "ok:fixtures-ignore-inherited-git-dir:$pass"; exit 0; }
echo "violation:fixtures-ignore-inherited-git-dir:$fail-failed"; exit 1
