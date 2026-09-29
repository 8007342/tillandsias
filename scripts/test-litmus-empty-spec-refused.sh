#!/usr/bin/env bash
# @trace order:1460-3gja
#
# test-litmus-empty-spec-refused.sh — run-litmus-test.sh given an EXPLICIT
# empty spec name must refuse, not run every spec. Measured on lenovinha
# 2026-09-28: a binding lookup returned nothing, `run-litmus-test.sh "$spec"`
# ran with "", and every spec ran for 1h47m until killed.
#
# Arms:
#   1 EMPTY     an explicit "" exits 3 with refused:empty-litmus-spec-argument
#               and runs no test
#   2 NAMED     (negative control) a real spec name passes the parser; nothing runs
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R="$ROOT/scripts/run-litmus-test.sh"
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }

# timeout bounds the pre-fix behaviour, which would otherwise run the suite.
out1="$(cd "$ROOT" && timeout 60 bash "$R" "" --phase pre-build --size instant --compact 2>&1)"; rc1=$?
if [ "$rc1" -eq 3 ] && grep -q 'refused:empty-litmus-spec-argument' <<<"$out1"; then
    ok "ARM1 an explicit empty spec is refused (rc=3) instead of running every spec"
else bad "ARM1 rc=$rc1 (124 means it started running the suite)"; fi

# ARM 2 must run NOTHING (yolanda 2026-09-28: a --list run hit its timeout
# under MSYS and stranded images/router/.sidecar.stamp.* in the checkout).
# A named spec followed by an unknown flag stops inside argument parsing, after
# the positional has been accepted and before any setup: exit 3, "Unknown
# option", and no empty-spec refusal.
out2="$(cd "$ROOT" && timeout 30 bash "$R" git-mirror-service --no-such-flag-1460 2>&1)"; rc2=$?
if [ "$rc2" -eq 3 ] && grep -q 'Unknown option' <<<"$out2" \
   && ! grep -q 'refused:empty-litmus-spec-argument' <<<"$out2"; then
    ok "ARM2 a named spec is accepted by the parser (it reached the next argument)"
else bad "ARM2 rc=$rc2 out='$(head -3 <<<"$out2" | tr '\n' '|')'"; fi

[ "$FAIL" -eq 0 ] && { echo "PASS: litmus-empty-spec-refused (1460-3gja)"; exit 0; }
echo "FAILED: litmus-empty-spec-refused (1460-3gja)"; exit 1
