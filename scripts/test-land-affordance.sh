#!/usr/bin/env bash
# @trace order:1247-lwek, order:1247-amcu, spec:ci-release
#
# Fixture for 1247-amcu slice 2: every refused:land:* verdict of
# land-on-platform-branch.sh is followed by "  why: …" and "  remedy: …" on
# stderr, and its verdict line is unchanged.
#
# Hermetic, in the test-land-merges-trunk.sh shape: a seed repo carrying the
# script under test and a stub build.sh (the gate), a bare scratch origin whose
# core.hooksPath is pinned (a forge's global one would redirect it), and clones
# that land into it.
#
#   1  refused:land:dirty-worktree        why/remedy; REMEDY EXECUTED (commit) -> lands
#   2  refused:land:trunk-merge-conflict  why/remedy; REMEDY EXECUTED (merge
#                                          origin/<trunk>, resolve, commit) -> lands
#   3  refused:land:gate-failed           why/remedy; REMEDY EXECUTED (fix the tree
#                                          the gate refused, commit) -> lands
#   4  STATIC: every refused:land:* line in the script is followed within three
#      lines by an _afford call (covers the sites a scratch origin cannot induce:
#      OOM kill, auth, push timeouts, exhausted attempts, prefix allocation)
#
#   PASS: land-affordance <n>/<n>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNDER_TEST="$ROOT/scripts/land-on-platform-branch.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok:   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && echo "      $2"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/land-afford.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$W"' EXIT INT TERM
export GIT_TERMINAL_PROMPT=0

# $1 = dir. Seed: linux-next (trunk) and windows-next, trunk advanced by one
# commit touching shared.txt; bare origin with its own hooks.
build_origin() {
    local w="$1"
    rm -rf "$w/seed" "$w/origin"
    git init -q -b linux-next "$w/seed"
    git -C "$w/seed" config user.email f@e.invalid
    git -C "$w/seed" config user.name f
    mkdir -p "$w/seed/scripts"
    cp "$UNDER_TEST" "$w/seed/scripts/land-on-platform-branch.sh"
    printf '#!/bin/sh\nexit 0\n' > "$w/seed/build.sh"
    chmod +x "$w/seed/build.sh"
    printf 'base\n' > "$w/seed/shared.txt"
    git -C "$w/seed" add -A >/dev/null 2>&1
    git -C "$w/seed" commit -qm base
    git -C "$w/seed" branch windows-next
    printf 'trunk version\n' > "$w/seed/shared.txt"
    git -C "$w/seed" commit -qam "trunk edits shared.txt"
    git init -q --bare "$w/origin"
    git -C "$w/origin" config core.hooksPath hooks
    git -C "$w/origin" symbolic-ref HEAD refs/heads/linux-next
    git -C "$w/seed" remote add origin "$w/origin"
    git -C "$w/seed" push -q origin linux-next windows-next
}
clone_on() { # $1 = branch, $2 = dest
    git clone -q "$W/origin" "$2"
    git -C "$2" config user.email f@e.invalid
    git -C "$2" config user.name f
    git -C "$2" config core.hooksPath "$2/.git/hooks"
    git -C "$2" checkout -q "$1"
}
land() { # $1 = clone dir, $2 = branch -> rc; output in $W/land.log
    ( cd "$1" && bash scripts/land-on-platform-branch.sh "$2" 2 ) >"$W/land.log" 2>&1
    echo $?
}
afford_follows() { # $1 = verdict prefix: the why/remedy pair appears after it
    awk -v v="$1" 'index($0, v) == 1 { f = 1; next } f && /^  why: / { w = 1 } f && /^  remedy: / { r = 1 } END { exit !(f && w && r) }' "$W/land.log"
}

# ARM 1 — dirty worktree.
build_origin "$W"; clone_on linux-next "$W/a1"
printf 'local change\n' > "$W/a1/local.txt"; git -C "$W/a1" add local.txt
rc="$(land "$W/a1" linux-next)"
if [ "$rc" = 1 ] && afford_follows "refused:land:dirty-worktree"; then
    git -C "$W/a1" commit -qm "commit the change, as the remedy says"
    rc2="$(land "$W/a1" linux-next)"
    if [ "$rc2" = 0 ]; then
        ok "ARM 1: dirty-worktree says why and what clears it, and the remedy (commit) lands"
    else
        bad "ARM 1: the remedy did not clear the refusal" "rc=$rc2 $(tail -3 "$W/land.log" | tr '\n' '|')"
    fi
else
    bad "ARM 1: dirty-worktree without its affordance" "rc=$rc $(head -4 "$W/land.log" | tr '\n' '|')"
fi

# ARM 2 — the mandated trunk merge conflicts on shared.txt.
build_origin "$W"; clone_on windows-next "$W/a2"
printf 'platform version\n' > "$W/a2/shared.txt"
git -C "$W/a2" commit -qam "platform edits shared.txt"
rc="$(land "$W/a2" windows-next)"
if [ "$rc" = 2 ] && afford_follows "refused:land:trunk-merge-conflict"; then
    ( cd "$W/a2" && git merge -q origin/linux-next >/dev/null 2>&1
      printf 'resolved\n' > shared.txt && git add shared.txt && git commit -qm "resolve, as the remedy says" ) >/dev/null 2>&1
    rc2="$(land "$W/a2" windows-next)"
    if [ "$rc2" = 0 ]; then
        ok "ARM 2: trunk-merge-conflict says why and what clears it, and the remedy (merge, resolve, commit) lands"
    else
        bad "ARM 2: the remedy did not clear the refusal" "rc=$rc2 $(tail -3 "$W/land.log" | tr '\n' '|')"
    fi
else
    bad "ARM 2: trunk-merge-conflict without its affordance" "rc=$rc $(grep -m2 refused "$W/land.log" | tr '\n' '|')"
fi

# ARM 3 — the gate refuses the tree.
build_origin "$W"; clone_on linux-next "$W/a3"
printf '#!/bin/sh\necho "violation:fixture:the tree is wrong"\nexit 1\n' > "$W/a3/build.sh"
git -C "$W/a3" commit -qam "a tree the gate refuses"
rc="$(land "$W/a3" linux-next)"
if [ "$rc" != 0 ] && afford_follows "refused:land:gate-failed"; then
    printf '#!/bin/sh\nexit 0\n' > "$W/a3/build.sh"
    git -C "$W/a3" commit -qam "fix what the gate named, as the remedy says"
    rc2="$(land "$W/a3" linux-next)"
    if [ "$rc2" = 0 ]; then
        ok "ARM 3: gate-failed says why and what clears it, and the remedy (fix, commit) lands"
    else
        bad "ARM 3: the remedy did not clear the refusal" "rc=$rc2 $(tail -3 "$W/land.log" | tr '\n' '|')"
    fi
else
    bad "ARM 3: gate-failed without its affordance" "rc=$rc $(grep -m2 refused "$W/land.log" | tr '\n' '|')"
fi

# ARM 4 — static: each refused:land:* line is followed by an _afford call.
missing="$(awk '
    { line[NR] = $0 }
    /echo "refused:land:/ { sites[++n] = NR }
    END {
        for (i = 1; i <= n; i++) {
            s = sites[i]; found = 0
            for (j = s + 1; j <= s + 3; j++) if (line[j] ~ /_afford /) found = 1
            if (!found) print s ": " line[s]
        }
    }' "$UNDER_TEST")"
sites="$(grep -c 'echo "refused:land:' "$UNDER_TEST")"
if [ -z "$missing" ] && [ "$sites" -ge 13 ]; then
    ok "ARM 4: all $sites refused:land:* sites are followed by an _afford call"
else
    bad "ARM 4: refusal sites without an affordance (sites=$sites)" "$missing"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: land-affordance $pass/$total (1247-lwek)"
    exit 0
fi
echo "FAIL: land-affordance $pass/$total (1247-lwek)"
exit 1
