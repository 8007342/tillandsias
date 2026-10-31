#!/usr/bin/env bash
# @trace spec:default-image, order:1864-qymj
# Litmus: a forge has a Lua interpreter on PATH, the startup context names it,
# and its two helpers behave:
#   lua-edit      batched asserted replace: refuses, changing nothing, unless
#                 every OLD occurs exactly once;
#   lua-conflict  resolves a merge-conflict hunk as ours, theirs or both.
# Runs inside the built forge image, where these live; the host has no lua.
#
# Exit: 0 pass, 1 fail, 3 could-not-run (no podman or no forge image).
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${TILLANDSIAS_TEST_FORGE_IMAGE:-localhost/tillandsias-forge:v$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")}"

command -v podman >/dev/null 2>&1 || { echo "could-not-run:forge-lua:no-podman"; exit 3; }
podman image exists "$IMAGE" || { echo "could-not-run:forge-lua:no-forge-image:$IMAGE"; exit 3; }

out="$(podman run --rm --network none --user forge --entrypoint bash "$IMAGE" -c '
cd /tmp
echo "lua-path=$(command -v lua || echo none)"
echo "lua-version=$(lua -v 2>&1 || echo none)"
echo "lfs=$(lua -e "require(\"lfs\") print(\"yes\")" 2>/dev/null || echo no)"
echo "lpeg=$(lua -e "require(\"lpeg\") print(\"yes\")" 2>/dev/null || echo no)"

mkdir -p ctx
( source /usr/local/lib/tillandsias/lib-common.sh >/dev/null 2>&1; inject_startup_context /tmp/ctx >/dev/null 2>&1 ) || true
present=$(grep -m1 "^\*\*Present:\*\*" ctx/.forge-startup-context.md 2>/dev/null || echo none)
echo "ctx-present=$present"

printf "alpha beta\ngamma alpha\n" > dup.txt; cp dup.txt dup.orig
lua-edit dup.txt alpha ALPHA >/dev/null 2>&1 && echo edit-dup=applied || echo edit-dup=refused
cmp -s dup.txt dup.orig && echo edit-dup-unchanged=yes || echo edit-dup-unchanged=no
printf "one two three\n" > ok.txt
lua-edit ok.txt one 1 three 3 >/dev/null 2>&1 && echo edit-ok=applied || echo edit-ok=refused
echo "edit-ok-content=$(cat ok.txt)"
printf "a b\n" > miss.txt; cp miss.txt miss.orig
lua-edit miss.txt a A zzz Z >/dev/null 2>&1 && echo edit-miss=applied || echo edit-miss=refused
cmp -s miss.txt miss.orig && echo edit-miss-unchanged=yes || echo edit-miss-unchanged=no

for side in ours theirs both; do
  printf "top\n<<<<<<< HEAD\nmine\n=======\nyours\n>>>>>>> topic\nend\n" > c.txt
  lua-conflict c.txt $side >/dev/null 2>&1 || echo "conflict-$side=refused"
  echo "conflict-$side=$(tr "\n" "," < c.txt)"
done
printf "plain\n" > none.txt
lua-conflict none.txt ours >/dev/null 2>&1 && echo conflict-none=applied || echo conflict-none=refused
' 2>&1)"
echo "$out"

fail=0
want() { grep -qxF -- "$1" <<<"$out" || { echo "FAIL: want '$1'"; fail=1; }; }
grep -qE '^lua-path=/' <<<"$out" || { echo "FAIL: lua is not on PATH"; fail=1; }
grep -qE '^lua-version=Lua 5\.' <<<"$out" || { echo "FAIL: lua -v did not print a version"; fail=1; }
want "lfs=yes"
want "lpeg=yes"
grep -qE '^ctx-present=.*`lua`' <<<"$out" || { echo "FAIL: the startup context's Present list does not name lua"; fail=1; }
want "edit-dup=refused"
want "edit-dup-unchanged=yes"
want "edit-ok=applied"
want "edit-ok-content=1 two 3"
want "edit-miss=refused"
want "edit-miss-unchanged=yes"
want "conflict-ours=top,mine,end,"
want "conflict-theirs=top,yours,end,"
want "conflict-both=top,mine,yours,end,"
want "conflict-none=refused"
[ "$fail" -eq 0 ] && echo "PASS: forge lua tooling (interpreter, context, lua-edit, lua-conflict)"
exit "$fail"
