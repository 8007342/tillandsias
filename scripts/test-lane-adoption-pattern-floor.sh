#!/usr/bin/env bash
# @trace spec:mcp-tool-socket
# @trace order:1929-gfxy
#
# litmus:lane-socket-survives-launcher-exit step 1 pinned
# "test result: ok. 5 passed". The lane_adoption_tests module grew to 7
# (1863-eckw, 1911-3dqo), so a green run was refused in two v56.10.31.1 cut
# gates. The pattern is now a FLOOR of 5 with no failures. These arms judge
# the pattern AS THE YAML PARSES IT, with the runner's own matcher (grep -E).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
. scripts/plan-binary-probe.sh
P="$(resolve_plan_binary 2>/dev/null)" || { echo "skip:lane-adoption-pattern-floor:no-plan-binary"; exit 0; }
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok:   $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

_json="$("$P" yaml-json openspec/litmus-tests/litmus-lane-socket-survives-launcher-exit.yaml 2>/dev/null)"
pat="$("$P" json get -r '.critical_path[0].success_pattern' <<<"$_json" 2>/dev/null)"
[ -n "$pat" ] || { echo "FAIL: could not read step 1's success_pattern"; exit 1; }
matches() { grep -qE -- "$1" <<<"$2"; }
line() { printf 'test result: ok. %s passed; %s failed; 0 ignored; 0 measured; 1272 filtered out; finished in 0.00s' "$1" "$2"; }

for n in 5 7 12; do
    if matches "$pat" "$(line "$n" 0)"; then ok "accepts $n passed, 0 failed"; else bad "refuses a green $n-test run: $pat"; fi
done
for case in "4 0" "7 1" "0 0"; do
    set -- $case
    if matches "$pat" "$(line "$1" "$2")"; then bad "accepts $1 passed, $2 failed — the floor or the no-failure clause is gone"; else ok "refuses $1 passed, $2 failed"; fi
done
if matches "$pat" "test result: FAILED. 7 passed; 1 failed"; then bad "accepts a FAILED result"; else ok "refuses a FAILED result"; fi
# The retired exact pin refuses today's real shape, which is why it went.
if matches 'test result: ok. 5 passed' "$(line 7 0)"; then
    bad "the retired exact pin accepts today's 7-test output — this arm has no subject"
else
    ok "the retired exact pin refuses today's 7-test output"
fi

[ "$fail" -eq 0 ] && { echo "ok:lane-adoption-pattern-floor:$pass/$pass (1929-gfxy)"; exit 0; }
echo "FAIL: lane-adoption-pattern-floor $pass/$((pass+fail))"; exit 1
