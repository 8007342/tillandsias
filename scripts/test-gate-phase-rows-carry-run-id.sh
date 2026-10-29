#!/usr/bin/env bash
# =============================================================================
# test-gate-phase-rows-carry-run-id.sh — order 1915-gtph
#
# The defect this pins: build.sh --check already flushed one `step:` row per
# phase into the timing ledger (765-dfry), but nothing tied those rows to the
# gate run that produced them. The build-check total row and its ~400 phase
# rows shared only a flush-time timestamp, and their `host` fields differed
# (the gate row read the host name, phase rows read the toolbox's), so "where
# did this gate's 24 minutes go" was a timestamp-join guess, and a failed gate
# flushed no phase rows at all.
#
# The fix: the gate mints one run id (_gate_run_id_begin), exports it, and every
# timing row written while it runs carries "run_id"; phase rows also carry
# their banner-to-banner "wall_ms" next to the measured duration_ms.
#
# This runs the REAL tracker functions cut out of build.sh as a stub gate with
# three phases and asserts three phase rows plus the total row, all sharing one
# non-empty run_id. Hermetic: no cargo, no podman, no network; records go to a
# temp TILLANDSIAS_TIMING_LOG inside the fixture's own temp dir.
#
# Run: scripts/test-gate-phase-rows-carry-run-id.sh   (exit 0 = pass)
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ran=0
pass() { ran=$((ran + 1)); echo "ok: $1"; }
bad()  { ran=$((ran + 1)); echo "FAIL: $1"; fail=1; }

HARNESS="$(mktemp -d "${TMPDIR:-/tmp}/gate-phase-run-id.XXXXXX")"
trap 'rm -rf "$HARNESS"' EXIT

sed -n '/^_now_ms() {/,/^}/p;/^_phase_close() {/,/^}/p;/^_step()  {/,/^}/p;/^_phase_emit_timing() {/,/^}/p;/^_run() {/,/^}/p;/^_gate_run_id_begin() {/,/^}/p' \
    "$ROOT/build.sh" > "$HARNESS/tracker.sh"

for fn in _now_ms _phase_close _step _phase_emit_timing _run _gate_run_id_begin; do
    if ! grep -q "^${fn}()" "$HARNESS/tracker.sh"; then
        bad "build.sh defines no ${fn} — the gate has no run id to give its phase rows"
        echo "fail: gate-phase-rows-carry-run-id (${ran} checks)"
        exit 1
    fi
done
pass "tracker functions extracted from the real build.sh"

LOG="$HARNESS/timing.jsonl"
: > "$LOG"
(
    set -uo pipefail
    SCRIPT_DIR="$ROOT"
    FLAG_GRAPHS=true
    CYAN=""; NC=""
    TILLANDSIAS_HOST_ID="fixturehost"
    TILLANDSIAS_TIMING_LOG="$LOG"
    export TILLANDSIAS_TIMING_LOG
    unset TILLANDSIAS_TIMING_RUN_ID
    _require_host_build_tools() { :; }
    # shellcheck disable=SC1090
    . "$ROOT/scripts/timing-log.sh"
    # shellcheck disable=SC1090
    . "$HARNESS/tracker.sh"
    _PHASE_NAME=""; _PHASE_T0=""; _PHASE_LOG=""; _PHASE_WORK_MS=0; _PHASE_RAN_WORK=0

    _gate_run_id_begin
    t0="$(timing_now_ms)"
    _step "stub phase one";   _run true
    _step "stub phase two";   _run true
    _step "stub phase three"; sleep 0.2
    _phase_emit_timing
    timing_emit build-check check "$t0" 0
) >/dev/null 2>&1

phase_rows="$(grep -c '"step":"step:stub-phase-' "$LOG" 2>/dev/null || true)"
total_rows="$(grep -c '"step":"build-check"' "$LOG" 2>/dev/null || true)"
[ "${phase_rows:-0}" -eq 3 ] && pass "three phase rows written" \
    || bad "expected 3 phase rows, got ${phase_rows:-0}"
[ "${total_rows:-0}" -eq 1 ] && pass "one build-check total row written" \
    || bad "expected 1 build-check row, got ${total_rows:-0}"

ids="$(grep -o '"run_id":"[^"]*"' "$LOG" 2>/dev/null | sort -u)"
n_ids="$(printf '%s' "$ids" | grep -c . || true)"
with_id="$(grep -c '"run_id":"[^"]' "$LOG" 2>/dev/null || true)"
if [ "${with_id:-0}" -eq 4 ] && [ "${n_ids:-0}" -eq 1 ]; then
    pass "all four rows carry one shared run_id (${ids})"
else
    bad "rows must share one run_id — ${with_id:-0}/4 rows carry one, ${n_ids:-0} distinct"
fi

wall_rows="$(grep '"step":"step:stub-phase-' "$LOG" 2>/dev/null | grep -c '"wall_ms":[0-9]' || true)"
[ "${wall_rows:-0}" -eq 3 ] && pass "every phase row carries wall_ms" \
    || bad "expected wall_ms on 3 phase rows, got ${wall_rows:-0}"

if [ "$fail" -eq 0 ]; then
    echo "ok:gate-phase-rows-carry-run-id-fixture:${ran}"
    exit 0
fi
echo "--- emitted records ---" >&2
cat "$LOG" >&2 2>/dev/null || true
echo "fail: gate-phase-rows-carry-run-id (${ran} checks)"
exit 1
