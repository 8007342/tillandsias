#!/usr/bin/env bash
# @trace order:890-27mv, spec:ci-release
#
# Fixture for check-release-tier-freshness.sh (890-27mv).
#
# REGIME: pure-source, hermetic, offline. Every arm builds its own
# check-logs.jsonl in a temp dir and points the script at it through
# TILLANDSIAS_CHECK_LOG_INDEX. It runs no release tier, needs no podman, no
# network and no inference endpoint, and asserts nothing about THIS host — so
# it is honest on every host in the fleet, including the ones that can never
# run the tier it reports on.
#
# NO ABSOLUTE MOMENT IS ENCODED (1130-i6xj). A fixture that hard-codes a date
# is a fixture with an expiry. The fresh arms stamp themselves with the current
# UTC moment at run time, and the STALE arm is produced by moving the
# THRESHOLD below zero rather than by fabricating an old timestamp — same
# branch, no clock arithmetic, nothing to expire.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-release-tier-freshness.sh"
pass=0; fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RUN_ID="local-ci-$(date -u +%Y%m%dT%H%M%SZ)"

rec() { # rec <run_id> <check_id> <status>
    printf '{"ci_run_id":"%s","ci_phase":"pre-build","check_id":"%s","status":"%s","source_log":"","archived_log":"a","sha256":"x","duration_ms":1}\n' "$1" "$2" "$3"
}

# run_guard <index-path-or-empty> [extra env assignments...]
run_guard() {
    local idx="$1"; shift
    TILLANDSIAS_CHECK_LOG_INDEX="$idx" "$@" bash "$GUARD" 2>&1
}

check() { # check <label> <expected-rc> <expected-token> <actual-rc> <output>
    local label="$1" erc="$2" tok="$3" arc="$4" out="$5"
    if [ "$arc" -eq "$erc" ] && printf '%s' "$out" | grep -q "$tok"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $label — expected rc=$erc and token '$tok', got rc=$arc"
        printf '%s\n' "$out" | sed 's/^/    /'
    fi
}

# 1. NEVER RUN. The index does not exist at all — yoga's real state on
#    2026-09-12, and the case the packet was filed for.
out="$(run_guard "$TMP/absent.jsonl")"; rc=$?
check "absent index reports never" 1 "never:release-tier:" "$rc" "$out"

# 2. A run started and recorded nothing. Distinct from absent, same verdict.
: > "$TMP/empty.jsonl"
out="$(run_guard "$TMP/empty.jsonl")"; rc=$?
check "empty index reports never" 1 "never:release-tier:" "$rc" "$out"

# 3. Fresh and green.
rec "$RUN_ID" spec-cheatsheet-binding pass >  "$TMP/green.jsonl"
rec "$RUN_ID" expert-groundtruth-harness pass >> "$TMP/green.jsonl"
out="$(run_guard "$TMP/green.jsonl")"; rc=$?
check "fresh all-pass is green" 0 "ok:release-tier-fresh:" "$rc" "$out"

# 4. Fresh but RED. A green age must not launder a red verdict.
cp "$TMP/green.jsonl" "$TMP/red.jsonl"
rec "$RUN_ID" expert-groundtruth-harness fail >> "$TMP/red.jsonl"
out="$(run_guard "$TMP/red.jsonl")"; rc=$?
check "a failing check reads red" 1 "red:release-tier:" "$rc" "$out"

# 5. STALE. Threshold below zero puts a just-written record past it without
#    inventing a date — see the regime note above.
out="$(TILLANDSIAS_RELEASE_TIER_MAX_AGE_DAYS=-1 run_guard "$TMP/green.jsonl")"; rc=$?
check "too old reads stale" 1 "stale:release-tier:" "$rc" "$out"

# 6. THE VERDICT COVERS THE WHOLE RUN, not just the last line. A red first and
#    a green last is the arrangement a tail -1 verdict gets wrong.
rec "$RUN_ID" a fail >  "$TMP/order.jsonl"
rec "$RUN_ID" b pass >> "$TMP/order.jsonl"
out="$(run_guard "$TMP/order.jsonl")"; rc=$?
check "a red before a green still reads red" 1 "red:release-tier:" "$rc" "$out"

# 7. Unreadable stamp routes to COULD-NOT-RUN, not to a verdict (965-sxec).
rec "local-ci-not-a-timestamp" a pass > "$TMP/bad.jsonl"
out="$(run_guard "$TMP/bad.jsonl")"; rc=$?
check "an unparseable run id could-not-run" 3 "could-not-run:release-tier:" "$rc" "$out"

# 8. NEGATIVE CONTROL, and the reason this guard exists at all: NOTHING that is
#    not a fresh green run may exit 0. A host that cannot run the heavier tier
#    must report that it did not run it — never that it passed. Arms 1-2 and
#    5-7 are re-asserted here as a set, because each of them individually
#    passing does not say that the SET of non-green outcomes is closed under
#    "never exits 0", and that is the property a caller depends on.
neg=0
for probe in "$TMP/absent.jsonl" "$TMP/empty.jsonl" "$TMP/bad.jsonl" "$TMP/red.jsonl"; do
    run_guard "$probe" >/dev/null 2>&1
    [ $? -eq 0 ] && neg=$((neg + 1))
done
TILLANDSIAS_RELEASE_TIER_MAX_AGE_DAYS=-1 run_guard "$TMP/green.jsonl" >/dev/null 2>&1
[ $? -eq 0 ] && neg=$((neg + 1))
if [ "$neg" -eq 0 ]; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: negative control — $neg non-green outcome(s) exited 0, which is a host claiming a tier passed when it never ran it"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: release-tier freshness guard $pass/$total (890-27mv)"
    exit 0
fi
echo "FAIL: release-tier freshness guard $pass/$total (890-27mv)"
exit 1
