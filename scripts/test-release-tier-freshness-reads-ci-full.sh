#!/usr/bin/env bash
# @trace order:1185-9qx6, spec:ci-release
#
# test-release-tier-freshness-reads-ci-full.sh — pin the WRITER/READER contract
# that 1185-9qx6 closed.
#
# THE DEFECT. check-release-tier-freshness.sh asks whether the RELEASE tier ran
# on this host, reading target/convergence/check-logs.jsonl, and since 1174-6r4k
# it correctly demands a FULL-tier run: ci_phase `all`, or pre-build AND
# post-build AND runtime between one run's records. Nothing could produce that.
# local-ci.sh is the index's only writer and ci-full drives only its pre-build
# phase through it; the post-build smoke and runtime litmus ran from build.sh
# and recorded nothing. Measured on macuahuitl 2026-09-14: a green ci-full, and
# all 245 records the index had ever held were pre-build — `never:release-tier`
# from the guard, about the very run it exists to notice.
#
# Hermetic: every arm writes a throwaway index under a temp dir and points the
# guard at it with TILLANDSIAS_CHECK_LOG_INDEX. This checkout's own index is
# never read or written, so the fixture's verdict does not depend on whether
# this host has ever run the tier.
#
# THE ARM THAT MATTERS IS THE NEGATIVE CONTROL (arm 2): a phase-only run must
# STILL read as not-a-release-tier-answer. The fix is on the writer precisely so
# that 1174-6r4k's narrowing does not have to be widened — if arm 2 ever goes
# green, the guard has been loosened back into reporting a pre-build gate as a
# release-tier answer, and the daily exercise will skip the real tier on it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3

GUARD="scripts/check-release-tier-freshness.sh"
RECORDER="scripts/record-ci-phase-result.sh"
[ -x "$GUARD" ] || { echo "skip:release-tier-ci-full:$GUARD is absent — nothing to exercise"; exit 3; }
[ -x "$RECORDER" ] || { echo "skip:release-tier-ci-full:$RECORDER is absent — nothing to exercise"; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "skip:release-tier-ci-full:no jq on PATH"; exit 3; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/release-tier-ci-full.XXXXXX")" || exit 3
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

# A run id dated NOW, so the age arithmetic reads it as fresh rather than stale.
RUN_ID="local-ci-$(date -u +%Y%m%dT%H%M%SZ)"

# A command substitution runs in a SUBSHELL, so a verdict-and-rc pair cannot be
# returned through one — the rc would be the subshell's. Capture to a file and
# read both in this shell (the same shape as the land-verdict-through-a-pipe
# rule, one layer down).
run_guard() { # run_guard <index>; sets OUT and GUARD_RC
    local idx="$1"
    TILLANDSIAS_CHECK_LOG_INDEX="$idx" bash "$GUARD" >"$TMP/guard.out" 2>&1
    GUARD_RC=$?
    OUT="$(cat "$TMP/guard.out")"
}

record() { # record <index> <phase> <status>
    TILLANDSIAS_CHECK_LOG_INDEX="$1" bash "$RECORDER" "$RUN_ID" "$2" "phase-$2" "$3" >/dev/null 2>&1
}

echo "arm 1 — a ci-full-shaped run (pre-build + post-build + runtime) reads FRESH"
IDX="$TMP/full.jsonl"
record "$IDX" pre-build pass
record "$IDX" post-build pass
record "$IDX" runtime pass
run_guard "$IDX"
if [ "$GUARD_RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "^ok:release-tier-fresh:$RUN_ID:"; then
    ok "ok:release-tier-fresh names the run ($RUN_ID), rc=0"
else
    bad "expected ok:release-tier-fresh:$RUN_ID at rc=0, got rc=$GUARD_RC: $OUT"
fi

echo "arm 2 — NEGATIVE CONTROL: a phase-only pre-build run still reads NOT-a-release-tier-answer"
IDX="$TMP/phase-only.jsonl"
record "$IDX" pre-build pass
run_guard "$IDX"
if [ "$GUARD_RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '^never:release-tier:'; then
    ok "never:release-tier at rc=$GUARD_RC — 1174-6r4k's narrowing is intact"
else
    bad "a pre-build-only run must NOT satisfy the guard; got rc=$GUARD_RC: $OUT"
fi

echo "arm 3 — a skipped runtime phase still covers the tier, and the verdict SAYS skip"
IDX="$TMP/runtime-skipped.jsonl"
record "$IDX" pre-build pass
record "$IDX" post-build pass
record "$IDX" runtime skipped
run_guard "$IDX"
if [ "$GUARD_RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '1 skip'; then
    ok "covered and reported as skip, not silently dropped"
else
    bad "expected rc=0 with the skip visible in the verdict line, got rc=$GUARD_RC: $OUT"
fi

echo "arm 4 — a failing phase records, and reads RED rather than never"
IDX="$TMP/red.jsonl"
record "$IDX" pre-build pass
record "$IDX" post-build fail
record "$IDX" runtime pass
run_guard "$IDX"
if [ "$GUARD_RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '^red:release-tier:'; then
    ok "red:release-tier — the red channel can fire, which needs the failing phase to record"
else
    bad "expected red:release-tier, got rc=$GUARD_RC: $OUT"
fi

echo "arm 5 — the recorder REFUSES a malformed run id (an undatable run reads could-not-run)"
IDX="$TMP/refuse.jsonl"
if TILLANDSIAS_CHECK_LOG_INDEX="$IDX" bash "$RECORDER" "ci-full-oops" runtime x pass >/dev/null 2>&1; then
    bad "recorder accepted a run id the guard cannot date"
elif [ -s "$IDX" ]; then
    bad "recorder refused but still wrote to the index"
else
    ok "refused, and wrote nothing"
fi

echo "arm 6 — the recorder REFUSES an unknown phase and an unknown status"
IDX="$TMP/refuse2.jsonl"
r1=0; TILLANDSIAS_CHECK_LOG_INDEX="$IDX" bash "$RECORDER" "$RUN_ID" smoke x pass >/dev/null 2>&1 || r1=$?
r2=0; TILLANDSIAS_CHECK_LOG_INDEX="$IDX" bash "$RECORDER" "$RUN_ID" runtime x green >/dev/null 2>&1 || r2=$?
if [ "$r1" -eq 2 ] && [ "$r2" -eq 2 ] && [ ! -s "$IDX" ]; then
    ok "both refused at rc=2 with nothing written"
else
    bad "expected rc=2 for both (got $r1, $r2) and an empty index"
fi

echo "arm 7 — local-ci.sh honours TILLANDSIAS_CI_RUN_ID and refuses a malformed one"
if grep -q 'TILLANDSIAS_CI_RUN_ID' scripts/local-ci.sh; then
    rc=0
    TILLANDSIAS_CI_RUN_ID="not-a-run-id" bash scripts/local-ci.sh --phase pre-build >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 2 ]; then
        ok "refused a malformed TILLANDSIAS_CI_RUN_ID at rc=2 before running anything"
    else
        bad "expected local-ci.sh to refuse a malformed run id at rc=2, got rc=$rc"
    fi
else
    bad "scripts/local-ci.sh does not read TILLANDSIAS_CI_RUN_ID — build.sh cannot correlate its phases"
fi

echo "arm 8 — build.sh records the phases it runs outside local-ci"
missing=""
grep -q '_record_ci_phase post-build' build.sh || missing="$missing post-build"
grep -q '_record_ci_phase runtime' build.sh || missing="$missing runtime"
grep -q 'export TILLANDSIAS_CI_RUN_ID' build.sh || missing="$missing run-id-export"
if [ -z "$missing" ]; then
    ok "post-build and runtime are recorded under an exported run id"
else
    bad "build.sh no longer records:$missing — a green ci-full would read never:release-tier again"
fi

echo
echo "release-tier ci-full contract: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    echo "violation:release-tier-ci-full:$fail"
    exit 1
fi
echo "ok:release-tier-ci-full:$pass"
exit 0
