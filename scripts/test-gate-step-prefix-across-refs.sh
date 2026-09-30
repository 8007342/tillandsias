#!/usr/bin/env bash
# @trace order:1512-3afc
#
# check-gate-step-prefix-across-refs.sh against a scratch repo with a bare
# remote. Trunk holds 100-a.step. The branch under test adds 110-mine.step.
#
#   1  another host's RECENT unlanded ref holds 110-other.step -> refused,
#      naming that ref and file, with why/remedy and a free prefix (120)
#   2  the same branch after git mv to 120 -> accepted
#   3  NEGATIVE CONTROL: the only holder of 110 is the branch's own pushed ref
#      (same file) -> accepted
#   4  a holder ref whose last commit is OLDER than the window -> ignored
#   5  a holder ref already merged into trunk -> ignored
#   6  no new steps -> ok:no-new-steps
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-gate-step-prefix-across-refs.sh"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/step-prefix-refs.XXXXXX")"
trap 'rm -rf "$W"' EXIT
export GIT_TERMINAL_PROMPT=0
G() { git -c user.email=t@t -c user.name=t "$@"; }
step() { mkdir -p scripts/gate-steps.d; printf 'STEP_SCRIPT="scripts/x.sh"\n' > "scripts/gate-steps.d/$1"; }
run() { bash "$CHECK" 2>"$W/err"; }

git init -q --bare "$W/bare.git"
git init -q -b linux-next "$W/wc"; cd "$W/wc" || exit 2
git remote add origin "$W/bare.git"; git config core.autocrlf false
step 100-a.step; G add -A; G commit -qm base; git push -q -u origin linux-next

# another host's recent work ref holding 110
G checkout -q -b work/other linux-next; step 110-other.step; G add -A; G commit -qm other
git push -q origin work/other
# an OLD work ref holding 130 (outside the window)
G checkout -q -b work/old linux-next; step 130-old.step; G add -A
GIT_COMMITTER_DATE="2020-01-01T00:00:00Z" GIT_AUTHOR_DATE="2020-01-01T00:00:00Z" G commit -qm old
git push -q origin work/old
# a work ref holding 140 that is already merged into trunk
G checkout -q linux-next; G checkout -q -b work/landed; step 140-landed.step; G add -A; G commit -qm landed
git push -q origin work/landed; G checkout -q linux-next; G merge -q --ff-only work/landed; git push -q origin linux-next

# the branch under test
G checkout -q -b work/mine linux-next
git fetch -q origin

# 6
out="$(run)"; rc=$?
case "$rc:$out" in 0:ok:gate-step-prefix-across-refs:no-new-steps) ok "arm 6: no new steps is ok";; *) bad "arm 6: rc=$rc [$out]";; esac

step 110-mine.step; G add -A; G commit -qm mine
# 1
out="$(run)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$out" = "refused:gate-step-prefix-across-refs:110-mine.step:origin/work/other:110-other.step" ] \
   && grep -q '^  why: ' "$W/err" && grep -q '^  remedy: .*120-mine.step' "$W/err"; then
    ok "arm 1: a prefix held by another recent unlanded ref is refused by name, remedy suggests 120"
else
    bad "arm 1: rc=$rc [$out] err=[$(tr '\n' ' ' < "$W/err")]"
fi

# 3 (before renaming): push our own ref; delete the rival, so our own is the only holder
git push -q origin work/mine; git push -q origin --delete work/other; git fetch -q --prune origin
out="$(run)"; rc=$?
case "$rc:$out" in 0:ok:gate-step-prefix-across-refs:*) ok "arm 3: our own pushed ref is not a rival ($out)";; *) bad "arm 3: rc=$rc [$out]";; esac

# 2: restore the rival, rename ours to 120
G push -q origin "$(git rev-parse HEAD~0)":refs/heads/tmp-noop 2>/dev/null; git push -q origin --delete tmp-noop 2>/dev/null
G checkout -q linux-next; G checkout -q -b work/other2; step 110-other.step; G add -A; G commit -qm other2; git push -q origin work/other2
G checkout -q work/mine; git fetch -q origin
G mv scripts/gate-steps.d/110-mine.step scripts/gate-steps.d/120-mine.step; G commit -qm rename
out="$(run)"; rc=$?
case "$rc:$out" in 0:ok:gate-step-prefix-across-refs:1\ added*) ok "arm 2: at a free prefix the same branch is accepted ($out)";; *) bad "arm 2: rc=$rc [$out]";; esac

# 4 and 5: 130 is held only by the OLD ref, 140 only by a ref merged into trunk
G mv scripts/gate-steps.d/120-mine.step scripts/gate-steps.d/130-mine.step; G commit -qm to130
out="$(run)"; rc=$?
case "$rc:$out" in 0:ok:*) ok "arm 4: a holder older than the window is ignored";; *) bad "arm 4: rc=$rc [$out]";; esac
# arm 4's control: widen the window and the same old ref IS a holder, so the
# pass above came from the window and not from the ref being invisible
out="$(TILLANDSIAS_STEP_PREFIX_WINDOW_DAYS=100000 bash "$CHECK" 2>/dev/null)"; rc=$?
case "$rc:$out" in 1:refused:gate-step-prefix-across-refs:130-mine.step:origin/work/old:130-old.step) ok "arm 4 control: with the window widened the old ref refuses";; *) bad "arm 4 control: rc=$rc [$out]";; esac
G mv scripts/gate-steps.d/130-mine.step scripts/gate-steps.d/150-mine.step; G commit -qm to150
step 145-x.step; G add -A; G commit -qm extra
out="$(run)"; rc=$?
case "$rc:$out" in 0:ok:*) ok "arm 5 (control): unrelated free prefixes are accepted";; *) bad "arm 5: rc=$rc [$out]";; esac
# 140 is on trunk itself (the merged ref landed it), so adding 140 again must refuse against TRUNK
step 140-dup.step; G add -A; G commit -qm dup
out="$(run)"; rc=$?
case "$rc:$out" in 1:refused:gate-step-prefix-across-refs:140-dup.step:origin/linux-next:140-landed.step) ok "arm 5: a prefix on trunk is refused against trunk, not the merged work ref";; *) bad "arm 5b: rc=$rc [$out]";; esac

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "ok:gate-step-prefix-across-refs-fixture:$pass/$total"; exit 0; fi
echo "violation:gate-step-prefix-across-refs-fixture:$pass/$total"; exit 1
