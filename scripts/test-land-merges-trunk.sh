#!/usr/bin/env bash
# @trace order:1064-r8fv
#
# Fixture: land-on-platform-branch.sh must merge TRUNK, not only the branch's
# own remote — and must not merge anything on trunk itself.
#
# WHAT WAS BROKEN, measured on yolanda 2026-09-05. The tool integrated onto
# origin/$BRANCH and nothing else. The pre-push guard
# (scripts/hooks/pre-push-linux-next-merged.sh) requires the branch to contain
# origin/LINUX-NEXT's head, a DIFFERENT ref on every platform branch, so the
# retry loop could exhaust its attempts and never satisfy it. Four consecutive
# refusals landing 1055-6yp8 from windows-next, three of them
# blocked:linux-next-not-merged, with the tool answering
# `refused:land:push-failed — not a lost race, so retrying cannot help`. True,
# and the wrong shape: the cause was one command away.
#
# It went unnoticed because on linux-next $BRANCH and trunk are the same ref, so
# the tool worked exactly where it was not needed and failed on the slow
# platform hosts it was written for.
#
# ARM 2 IS THE NEGATIVE CONTROL AND IT IS THE ONE THAT MATTERS. A "fix" that
# merges trunk unconditionally would pass arm 1 and be wrong: on trunk there is
# nothing to merge, and a tool that manufactures an empty merge commit on every
# land pollutes the history it is supposed to protect. Arm 1 says "satisfy the
# guard"; arm 2 says "and do nothing when there is nothing to do".
#
# NO NETWORK AND NO REAL GATE. origin is a local bare repo and ./build.sh is a
# stub that exits 0, because what is under test is which refs get merged, not
# whether the workspace compiles.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNDER_TEST="$ROOT/scripts/land-on-platform-branch.sh"
[ -f "$UNDER_TEST" ] || { echo "SKIP: land-on-platform-branch.sh not present" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: no git(1)" >&2; exit 0; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

pass=0
fail=0
_result() { # name expected actual
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "  FAIL $1: expected [$2] got [$3]" >&2
    fi
}

_git() { git -C "$1" "${@:2}"; }

# A bare origin carrying linux-next and windows-next, with trunk AHEAD.
build_origin() { # $1 = work dir
    local w="$1"
    mkdir -p "$w/seed"
    git -C "$w/seed" init -q -b linux-next
    git -C "$w/seed" config user.email f@e.invalid
    git -C "$w/seed" config user.name f
    mkdir -p "$w/seed/scripts"
    cp "$UNDER_TEST" "$w/seed/scripts/land-on-platform-branch.sh"
    printf '#!/bin/sh\nexit 0\n' > "$w/seed/build.sh"
    chmod +x "$w/seed/build.sh"
    printf 'base\n' > "$w/seed/base.txt"
    git -C "$w/seed" add -A >/dev/null 2>&1
    git -C "$w/seed" commit -qm base
    git -C "$w/seed" branch windows-next
    # trunk moves ahead, on a path the platform branch never touches
    printf 'trunk moved\n' > "$w/seed/trunk-only.txt"
    git -C "$w/seed" add trunk-only.txt >/dev/null 2>&1
    git -C "$w/seed" commit -qm "trunk advances"
    git init -q --bare "$w/origin"
    git -C "$w/seed" remote add origin "$w/origin"
    git -C "$w/seed" push -q origin linux-next windows-next
}

# A working clone sitting on $2 with one unpushed commit.
build_clone() { # $1 = work dir, $2 = branch, $3 = dest
    git clone -q "$1/origin" "$3"
    git -C "$3" config user.email f@e.invalid
    git -C "$3" config user.name f
    git -C "$3" checkout -q "$2"
    printf 'local work\n' > "$3/work-$2.txt"
    git -C "$3" add "work-$2.txt" >/dev/null 2>&1
    git -C "$3" commit -qm "work on $2"
}

echo "== 1064-r8fv: land-on-platform-branch merges trunk on a platform branch"

# ---- ARM 1: on a platform branch, trunk must end up contained ---------------
build_origin "$WORK"
build_clone "$WORK" windows-next "$WORK/win"
trunk_head="$(git -C "$WORK/origin" rev-parse linux-next)"
( cd "$WORK/win" && bash scripts/land-on-platform-branch.sh windows-next 2 ) >"$WORK/win.log" 2>&1
land_rc=$?
if git -C "$WORK/win" merge-base --is-ancestor "$trunk_head" HEAD 2>/dev/null; then
    contained=yes
else
    contained=no
fi
_result "arm1-trunk-is-contained-after-land" "yes" "$contained"
_result "arm1-land-succeeded" "0" "$land_rc"
# and it must actually be on the REMOTE, which is the only proof that counts
if git -C "$WORK/origin" merge-base --is-ancestor "$trunk_head" windows-next 2>/dev/null; then
    pushed=yes
else
    pushed=no
fi
_result "arm1-pushed-head-contains-trunk" "yes" "$pushed"

# ---- ARM 2: NEGATIVE CONTROL — on trunk itself, no extra merge --------------
# Nothing to merge here. A fix that merges unconditionally would add an empty
# merge commit on every land; that must not happen.
rm -rf "$WORK/origin" "$WORK/seed"
build_origin "$WORK"
build_clone "$WORK" linux-next "$WORK/lin"
before="$(git -C "$WORK/lin" rev-list --count HEAD)"
before_merges="$(git -C "$WORK/lin" rev-list --merges --count HEAD)"
( cd "$WORK/lin" && bash scripts/land-on-platform-branch.sh linux-next 2 ) >"$WORK/lin.log" 2>&1
after_merges="$(git -C "$WORK/lin" rev-list --merges --count HEAD)"
_result "arm2-no-merge-commit-manufactured-on-trunk" "$before_merges" "$after_merges"
if grep -q "merging origin/linux-next" "$WORK/lin.log" 2>/dev/null; then
    said=yes
else
    said=no
fi
_result "arm2-does-not-announce-a-trunk-merge-on-trunk" "no" "$said"

# ---- ARM 3: a refusal must NAME the relay lane, and must not take it --------
# A push the remote rejects outright is not a lost race. The tool must refuse
# and point at the relay; it must never retarget the push itself.
rm -rf "$WORK/origin" "$WORK/seed"
build_origin "$WORK"
build_clone "$WORK" windows-next "$WORK/rej"
printf '#!/bin/sh\necho "refused by fixture" >&2\nexit 1\n' > "$WORK/origin/hooks/pre-receive"
chmod +x "$WORK/origin/hooks/pre-receive"
( cd "$WORK/rej" && bash scripts/land-on-platform-branch.sh windows-next 2 ) >"$WORK/rej.log" 2>&1
rej_rc=$?
_result "arm3-refuses-rather-than-claiming-success" "6" "$rej_rc"
if grep -q "refs/heads/work/" "$WORK/rej.log" 2>/dev/null; then named=yes; else named=no; fi
_result "arm3-names-the-relay-lane" "yes" "$named"
# It must NOT have created the relay ref itself.
if git -C "$WORK/origin" show-ref --verify --quiet refs/heads/work/1064-r8fv 2>/dev/null; then
    took=yes
else
    took=no
fi
_result "arm3-does-not-retarget-the-push-itself" "no" "$took"

echo "PASS: $pass  FAIL: $fail"
if [ "$fail" -gt 0 ]; then
    echo "violation:land-merges-trunk:$fail arm(s) failed"
    exit 1
fi
echo "ok:land-merges-trunk:$pass arm(s)"
