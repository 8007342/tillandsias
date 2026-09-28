#!/usr/bin/env bash
# @trace order:1460-3gja
#
# test-litmus-empty-spec-refused.sh — run-litmus-test.sh given an EXPLICIT
# empty spec name must refuse, not run every spec. Measured on lenovinha
# 2026-09-28: a binding lookup returned nothing, `run-litmus-test.sh "$spec"`
# ran with "", and every spec ran for 1h47m until killed.
#
# Arms:
#   1 EMPTY     an explicit "" exits 3 with refused:litmus:empty-spec-argument
#               and runs no test
#   2 NAMED     (negative control) a real spec name is not refused by this rule
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R="$ROOT/scripts/run-litmus-test.sh"
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }

# timeout bounds the pre-fix behaviour, which would otherwise run the suite.
out1="$(cd "$ROOT" && timeout 60 bash "$R" "" --phase pre-build --size instant --compact 2>&1)"; rc1=$?
if [ "$rc1" -eq 3 ] && grep -q 'refused:litmus:empty-spec-argument' <<<"$out1"; then
    ok "ARM1 an explicit empty spec is refused (rc=3) instead of running every spec"
else bad "ARM1 rc=$rc1 (124 means it started running the suite)"; fi

out2="$(cd "$ROOT" && timeout 60 bash "$R" git-mirror-service --list 2>&1)"; rc2=$?
if grep -q 'refused:litmus:empty-spec-argument' <<<"$out2"; then
    bad "ARM2 a named spec was refused by the empty-spec rule"
else ok "ARM2 a named spec is not refused by this rule (rc=$rc2)"; fi

[ "$FAIL" -eq 0 ] && { echo "PASS: litmus-empty-spec-refused (1460-3gja)"; exit 0; }
echo "FAILED: litmus-empty-spec-refused (1460-3gja)"; exit 1
