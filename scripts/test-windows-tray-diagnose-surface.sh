#!/usr/bin/env bash
# @trace spec:windows-native-tray
#
# Fixture for scripts/check-windows-tray-diagnose-surface.sh (order 624-cf9f).
#
# The check replaced eight grep-for-a-function-name litmus steps with one that
# RUNS the tests. That is stronger only if it can be shown to fail — a guard
# nobody has watched fail is not known to guard anything (622-rmit's own words).
# Every verdict in its grammar is proven reachable here, including the two that
# only occur when the toolchain is broken, because misreporting THAT was the
# first version's bug: it named a specific test as missing when the truth was
# that cargo never ran.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-windows-tray-diagnose-surface.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$CHECK" ] || fail "check not found: $CHECK"

# A transcript with every pinned test passing. Generated from the real list so
# the fixture cannot drift away from what the check demands.
all_ok() {
    local names
    names="$(sed -n '/^PINNED_TESTS=(/,/^)/p' "$CHECK" | grep -E '^ {4}[a-z_]+$' | tr -d ' ')"
    while IFS= read -r t; do
        [ -n "$t" ] && printf 'test notify_icon::tests::%s ... ok\n' "$t"
    done <<< "$names"
    printf 'test result: ok. 40 passed; 0 failed; 0 ignored\n'
}

run() { TRAY_DIAGNOSE_FIXTURE_OUTPUT="$1" bash "$CHECK" 2>/dev/null; }

# --- case 1: a healthy run verifies the surface ------------------------------
out="$(run "$(all_ok)")"
case "$out" in
    ok:diagnose-surface-verified:*) ;;
    *) fail "case 1: a passing run must verify, got '$out'" ;;
esac
echo "ok: case 1 — a passing run verifies the surface ($out)"

# --- case 2 (NEGATIVE CONTROL): a renamed/deleted pinned test is caught ------
# This is what the eight grep steps were protecting, so the replacement must
# still catch it.
without_one="$(all_ok | grep -v 'status_once_json_keys_pinned')"
out="$(run "$without_one")"
[ "$out" = "violation:diagnose-surface:missing-test:status_once_json_keys_pinned" ] \
    || fail "case 2: a missing pinned test must be named, got '$out'"
echo "ok: case 2 — a missing pinned test is caught and named"

# --- case 3 (NEGATIVE CONTROL): a FAILING pinned test is caught --------------
# The grep steps could not see this at all: a test whose name is present and
# whose body is red passed every one of them.
failing="$(all_ok | sed 's/^test notify_icon::tests::exit_code_provisioned_zero_degraded_two \.\.\. ok$/test notify_icon::tests::exit_code_provisioned_zero_degraded_two ... FAILED/')"
out="$(run "$failing")"
[ "$out" = "violation:diagnose-surface:tests-failed:exit_code_provisioned_zero_degraded_two" ] \
    || fail "case 3: a failing pinned test must be named, got '$out'"
echo "ok: case 3 — a failing pinned test is caught (the grep could not see this)"

# --- case 4: a blocked toolchain is a SKIP, never a violation ----------------
# Smart App Control on this host intermittently blocks freshly built unsigned
# binaries. Reporting that as a missing test sends the next agent hunting for a
# deleted function that is still there.
blocked="error: command failed: 'cargo': An Application Control policy has blocked this file. (os error 4551)"
out="$(run "$blocked")"
[ "$out" = "skip:diagnose-surface-unverifiable:windows-toolchain-blocked" ] \
    || fail "case 4: a blocked toolchain must skip, got '$out'"
echo "ok: case 4 — a blocked toolchain skips rather than accusing a test"

# --- case 5: output with no test results at all is a SKIP --------------------
out="$(run "warning: unused import
error: could not compile")"
[ "$out" = "skip:diagnose-surface-unverifiable:no-test-run" ] \
    || fail "case 5: a run with no test results must skip, got '$out'"
echo "ok: case 5 — no test results is reported as such"

# --- case 6: skips exit 0, violations exit 1 ---------------------------------
TRAY_DIAGNOSE_FIXTURE_OUTPUT="$blocked" bash "$CHECK" >/dev/null 2>&1 \
    || fail "case 6: a skip must exit 0 so a non-Windows lane is not failed by it"
if TRAY_DIAGNOSE_FIXTURE_OUTPUT="$without_one" bash "$CHECK" >/dev/null 2>&1; then
    fail "case 6: a violation must exit non-zero"
fi
echo "ok: case 6 — exit codes match the verdicts"

echo "PASS: windows tray diagnose surface check (6/6)"
