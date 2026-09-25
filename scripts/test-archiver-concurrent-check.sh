#!/usr/bin/env bash
# test-archiver-concurrent-check.sh — two archiver --check runs in ONE checkout
# must not break each other.
# @trace order:1132-r4mt
# @trace order:1141-vf9w (the stray gate that makes two runs concurrent)
#
# THE DEFECT. On Linux the archiver's scratch was $REPO_ROOT itself, so two
# concurrent `scripts/archive-plan-packets.sh --check` runs shared plan_tmp/,
# plan_tmp_bak/ and scripts/archive-plan-packets-check.rb, and each run's
# cleanup deleted them under the other. MEASURED on yoga 2026-09-25 at
# b862d02f3, 3 pairs out of 3: one run of each pair returned rc=3
# (ruby-worker-failed / unreadable-fragment, no "no usable ruby" token, the
# 2026-09-12 arm-4 shape) or a FALSE rc=1 "Not idempotent", while its partner
# passed. Standalone never has a partner, which is why it always passed there.
#
# Not hermetic, deliberately: the race lives in the real scratch paths and the
# real answerability harness, so a stubbed archiver could not exhibit it. Slow
# (each pair is two full archiver checks), so it is NOT in the --check gate;
# run it by hand when touching either script:
#     scripts/test-archiver-concurrent-check.sh [pairs]      # default 3
# PASS needs every run of every pair rc=0 and a clean worktree afterwards.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
pairs="${1:-3}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/archiver-concurrent.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
pass=0; fail=0
for t in $(seq 1 "$pairs"); do
    ( scripts/archive-plan-packets.sh --check >"$OUT/$t.a" 2>&1; echo $? >"$OUT/$t.a.rc" ) &
    sleep $(( t * 3 - 1 ))   # 2s, 5s, 8s ...: the offsets that hit on yoga
    ( scripts/archive-plan-packets.sh --check >"$OUT/$t.b" 2>&1; echo $? >"$OUT/$t.b.rc" ) &
    wait
    for s in a b; do
        rc="$(cat "$OUT/$t.$s.rc")"
        if [ "$rc" = 0 ]; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
            echo "FAIL: pair $t run $s rc=$rc — what the archiver said:"
            grep -E 'could-not-run|Check|No such|fail:' "$OUT/$t.$s" | sed -n '1,6p' | sed 's/^/    /'
        fi
    done
done
dirty="$(git status --porcelain --untracked-files=all -- plan_tmp plan_tmp_bak scripts/archive-plan-packets-check.rb toolbox)"
if [ -n "$dirty" ]; then
    fail=$((fail + 1)); echo "FAIL: concurrent runs left scratch in the worktree:"; echo "$dirty"
fi
total=$(( pairs * 2 ))
if [ "$fail" -eq 0 ]; then
    echo "PASS: archiver concurrent --check ${pass}/${total} (1132-r4mt)"
    exit 0
fi
echo "FAIL: archiver concurrent --check ${pass}/${total} passed, ${fail} failure(s) (1132-r4mt)"
exit 1
