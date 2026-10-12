#!/usr/bin/env bash
# @trace order:1512-3afc, order:1629-xtfw
#
# scripts/lua/check-gate-step-prefix-across-refs.lua against a scratch repo with a bare
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
#   7  a collision on 085 is refused (pre-1629-xtfw: an octal error, then ok)
#   8  a collision on 020 suggests 30, the base-10 next ten (pre-fix: 20)
#   9  010 collides with a held 10: one prefix in base 10 (pre-fix: passed)
set -uo pipefail
# 1592-idmu: this fixture builds its own repo, so the gate's frozen base (a SHA of
# the gated checkout) is not its base; its scratch origin/linux-next is.
unset TILLANDSIAS_GATE_DIFF_BASE
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 1628-re39: the check is Lua, run through the plan binary from inside the
# scratch clone (git runs in the caller's cwd, so it judges that clone).
CHECK="$ROOT/scripts/lua/check-gate-step-prefix-across-refs.lua"
PLAN_BIN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary)" || {
    echo "could-not-run:gate-step-prefix-across-refs-fixture:no-plan-binary"
    exit 3
}
# the probe may answer repo-relative; the arms run from the scratch clone
case "$PLAN_BIN" in /*|[A-Za-z]:*) ;; *) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac
chk() { "$PLAN_BIN" script run "$CHECK"; }
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/step-prefix-refs.XXXXXX")"
trap 'rm -rf "$W"' EXIT
# The runner's proc.run audit log defaults to <checkout>/.cache/metrics/
# (1443-w9hf); here the checkout is the scratch clone, whose `add -A` would
# commit it and whose next checkout then aborts on it. Keep it beside the clone.
export TILLANDSIAS_POLICY_AUDIT_LOG="$W/command-policy-audit.jsonl"
export GIT_TERMINAL_PROMPT=0
G() { git -c user.email=t@t -c user.name=t "$@"; }
step() { mkdir -p scripts/gate-steps.d; printf 'STEP_SCRIPT="scripts/x.sh"\n' > "scripts/gate-steps.d/$1"; }
run() { chk 2>"$W/err"; }

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
out="$(TILLANDSIAS_STEP_PREFIX_WINDOW_DAYS=100000 chk 2>/dev/null)"; rc=$?
case "$rc:$out" in 1:refused:gate-step-prefix-across-refs:130-mine.step:origin/work/old:130-old.step) ok "arm 4 control: with the window widened the old ref refuses";; *) bad "arm 4 control: rc=$rc [$out]";; esac
G mv scripts/gate-steps.d/130-mine.step scripts/gate-steps.d/150-mine.step; G commit -qm to150
step 145-x.step; G add -A; G commit -qm extra
out="$(run)"; rc=$?
case "$rc:$out" in 0:ok:*) ok "arm 5 (control): unrelated free prefixes are accepted";; *) bad "arm 5: rc=$rc [$out]";; esac
# 140 is on trunk itself (the merged ref landed it), so adding 140 again must refuse against TRUNK
step 140-dup.step; G add -A; G commit -qm dup
out="$(run)"; rc=$?
case "$rc:$out" in 1:refused:gate-step-prefix-across-refs:140-dup.step:origin/linux-next:140-landed.step) ok "arm 5: a prefix on trunk is refused against trunk, not the merged work ref";; *) bad "arm 5b: rc=$rc [$out]";; esac

# 7, 8, 9 (1629-xtfw): prefixes are read in BASE 10. A rival recent ref holds
# 085, 020 and 10; each arm starts a fresh branch from trunk.
G checkout -q linux-next; G checkout -q -b work/octal
step 085-r.step; step 020-r.step; step 10-r.step; G add -A; G commit -qm octal; git push -q origin work/octal
git fetch -q origin
# 7: a collision on 085 is refused, and it is the FIRST added step, so 110-m
# behind it (held by work/other2) is no longer hidden. Pre-fix: bash read 085 as
# octal, the error aborted the loop, and the check said ok:...:1 added.
G checkout -q -B work/mine2 linux-next; step 085-m.step; step 110-m.step; G add -A; G commit -qm arm7
out="$(run)"; rc=$?
case "$rc:$out" in 1:refused:gate-step-prefix-across-refs:085-m.step:origin/work/octal:085-r.step) ok "arm 7: a collision on 085 is refused, not passed as an octal error";; *) bad "arm 7: rc=$rc [$out] err=[$(tr '\n' ' ' < "$W/err")]";; esac
# 8: a collision on 020 suggests 30, the next base-10 ten. Pre-fix: 20 (octal 16).
G checkout -q -B work/mine2 linux-next; step 020-m.step; G add -A; G commit -qm arm8
out="$(run)"; rc=$?
if [ "$rc" -eq 1 ] && [ "$out" = "refused:gate-step-prefix-across-refs:020-m.step:origin/work/octal:020-r.step" ] \
   && grep -q '^  remedy: .*/30-m\.step ' "$W/err"; then
    ok "arm 8: a collision on 020 suggests the base-10 free prefix 30"
else
    bad "arm 8: rc=$rc [$out] err=[$(tr '\n' ' ' < "$W/err")]"
fi
# 9: THE DECISION: 010 and 10 are the same prefix (base 10), so they collide.
# Pre-fix they compared as strings and passed.
G checkout -q -B work/mine2 linux-next; step 010-m.step; G add -A; G commit -qm arm9
out="$(run)"; rc=$?
case "$rc:$out" in 1:refused:gate-step-prefix-across-refs:010-m.step:origin/work/octal:10-r.step) ok "arm 9: 010 collides with a held 10 (one prefix, base 10)";; *) bad "arm 9: rc=$rc [$out] err=[$(tr '\n' ' ' < "$W/err")]";; esac

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "ok:gate-step-prefix-across-refs-fixture:$pass/$total"; exit 0; fi
echo "violation:gate-step-prefix-across-refs-fixture:$pass/$total"; exit 1
