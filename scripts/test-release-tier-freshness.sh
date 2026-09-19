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

# ORDER 1174-6r4k. This helper used to hardcode ci_phase:"pre-build", which
# every arm below meant as "a run" — but once the guard learned to tell a FULL
# tier from a phase-only one, those arms were all writing partial runs and the
# guard correctly refused to call any of them a release-tier answer. They are
# full runs now (`all`, which is what local-ci.sh writes for a whole run) and
# the phase-only case has its own helper, because it is a distinct subject
# rather than the default.
rec() { # rec <run_id> <check_id> <status>          -> a FULL-tier record
    printf '{"ci_run_id":"%s","ci_phase":"all","check_id":"%s","status":"%s","source_log":"","archived_log":"a","sha256":"x","duration_ms":1}\n' "$1" "$2" "$3"
}

rec_phase() { # rec_phase <run_id> <phase> <check_id> <status>  -> one phase only
    printf '{"ci_run_id":"%s","ci_phase":"%s","check_id":"%s","status":"%s","source_log":"","archived_log":"a","sha256":"x","duration_ms":1}\n' "$1" "$2" "$3" "$4"
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

# ── ORDER 1174-6r4k: a phase-only run must not become the tier's answer ─────
#
# THE MEASURED CASE (macuahuitl, 2026-09-13 23:39Z, mid-cut): a diagnostic
# `scripts/local-ci.sh --phase pre-build` run — the cheapest way to reproduce a
# gate-only red — appended local-ci-20260913T233926Z as the newest run. Green,
# the daily 890-27mv exercise would have read fresh and skipped the real tier.
#
# Run ids are ordered by their embedded timestamp, and the FULL run is written
# OLDER than the phase-only one on purpose: the defect is precisely that the
# newest record wins regardless of coverage.
_full_old="local-ci-20260913T120000Z"
_partial_new="local-ci-20260913T233926Z"

# 9. newest is phase-only and GREEN, last full run is RED -> the full run wins.
{ rec "$_full_old" alpha fail
  rec "$_full_old" beta pass
  rec_phase "$_partial_new" pre-build gamma pass
} > "$TMP/phase-only.jsonl"
out="$(run_guard "$TMP/phase-only.jsonl")"; rc=$?
check "a green phase-only run does not mask the last full run's red" 1 "red:release-tier:" "$rc" "$out"
check "and the ignored run is named" 1 "skip:phase-only-run:$_partial_new" "$rc" "$out"

# 10. NEGATIVE CONTROL: newest run is FULL and red -> unchanged behaviour.
#     The point of the discriminator is coverage, never leniency: a full red run
#     must still read red with its count, exactly as before this order.
{ rec "$_full_old" alpha pass
  rec "local-ci-20260913T235000Z" beta fail
} > "$TMP/full-red.jsonl"
out="$(run_guard "$TMP/full-red.jsonl")"; rc=$?
check "NC: a full red run still reads red with its count" 1 "red:release-tier:1 failing" "$rc" "$out"

# 11. a run that did every phase SEPARATELY has exercised the tier.
#     Coverage, not the literal word "all" — otherwise three deliberate phase
#     runs would read as no tier answer at all.
#     Uses $RUN_ID, derived from NOW by the harness above, so this arm asserts
#     a FRESH verdict without encoding a date that would rot into staleness on
#     its own — the arms above are ordered relative to EACH OTHER and their
#     verdicts (red, never) do not depend on age at all.
{ rec_phase "$RUN_ID" pre-build a pass
  rec_phase "$RUN_ID" post-build b pass
  rec_phase "$RUN_ID" runtime c pass
} > "$TMP/covered.jsonl"
out="$(run_guard "$TMP/covered.jsonl")"; rc=$?
check "phases covered separately count as a full tier" 0 "ok:release-tier-fresh:" "$rc" "$out"

# 12. NOTHING BUT PHASE-ONLY RUNS IS "never", NOT "fresh".
#     The failure this order removes, in its purest form: green partial records
#     and no tier answer anywhere. Reporting that as fresh is what would skip
#     the daily exercise.
{ rec_phase "$_partial_new" pre-build gamma pass; } > "$TMP/only-partial.jsonl"
out="$(run_guard "$TMP/only-partial.jsonl")"; rc=$?
check "an index of only phase-only runs reports never, not fresh" 1 "never:release-tier:no FULL-tier run" "$rc" "$out"

# 13. THE WRITER HONOURS THE SAME OVERRIDE THE READER DOES.
#     Source text: running local-ci.sh here would run the tier. The assignment
#     is the contract, and before this order it was a fixed path — so a
#     diagnostic run could not be pointed away from the record.
_lci="$(cd "$(dirname "$GUARD")/.." && pwd)/scripts/local-ci.sh"
if [ -f "$_lci" ] && /usr/bin/grep -q 'CHECK_LOG_INDEX="${TILLANDSIAS_CHECK_LOG_INDEX:-' "$_lci"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1))
    echo "FAIL: local-ci.sh does not honour TILLANDSIAS_CHECK_LOG_INDEX — a diagnostic run still cannot be pointed away from the record the daily exercise reads"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: release-tier freshness guard $pass/$total (890-27mv)"
    exit 0
fi
echo "FAIL: release-tier freshness guard $pass/$total (890-27mv)"
exit 1
