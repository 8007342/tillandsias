#!/usr/bin/env bash
# =============================================================================
# test-build-step-timing-attribution.sh — order 785-ibu9
#
# The defect this pins: build.sh's phase tracker closes a phase when the NEXT
# banner prints, so a step's record measured BANNER TO BANNER and silently
# absorbed any work done between the named step's command and the next banner.
# A guard costing milliseconds could therefore surface as seconds, and one
# packet (783-xyk5) was filed on exactly such an inflated reading.
#
# The fix measures the step's OWN work — the time spent inside `_run` — and
# falls back to the span only for phases that run no `_run` at all, labelling
# that fallback in the record's `phase` field (`build` = attributable to the
# named step, `build-span` = wall clock between banners).
#
# These scenarios exercise the REAL tracker functions, sourced out of build.sh,
# against a scripted phase sequence with a deliberately slow unnamed block —
# the shape that produced the misattribution. Hermetic: no cargo, no podman,
# no network; the emitted records go to a temp TILLANDSIAS_TIMING_LOG.
#
# Run: scripts/test-build-step-timing-attribution.sh   (exit 0 = pass)
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
pass() { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

# Extract the tracker + _run from build.sh and run them in a harness that
# stands in for the gate. Sourcing build.sh itself would execute the whole
# build, so the functions are cut out by name — if a rename ever breaks this
# extraction the harness fails loudly rather than testing nothing (asserted
# immediately below).
HARNESS="$(mktemp -d)"
trap 'rm -rf "$HARNESS"' EXIT

sed -n '/^_now_ms() {/,/^}/p;/^_phase_close() {/,/^}/p;/^_step()  {/,/^}/p;/^_phase_emit_timing() {/,/^}/p;/^_run() {/,/^}/p' \
    "$ROOT/build.sh" > "$HARNESS/tracker.sh"

for fn in _now_ms _phase_close _step _phase_emit_timing _run; do
    grep -q "^${fn}()" "$HARNESS/tracker.sh" \
        || { bad "harness could not extract ${fn} from build.sh — the extraction, not the tracker, is broken"; exit 1; }
done
pass "tracker functions extracted from the real build.sh"

# ── Scenario 1: a fast named step followed by SLOW UNNAMED work ─────────────
# This is the misattribution shape. `fast-guard` runs a ~0s command and is then
# followed by a 1s sleep that belongs to nobody, before the next banner.
run_sequence() {
    local log="$1"
    (
        set -uo pipefail
        SCRIPT_DIR="$ROOT"
        FLAG_GRAPHS=true            # silence the banners
        CYAN=""; NC=""
        TILLANDSIAS_HOST_ID="fixturehost"
        _require_host_build_tools() { :; }   # the harness is not building anything
        # shellcheck disable=SC1090
        . "$HARNESS/tracker.sh"
        _PHASE_NAME=""; _PHASE_T0=""; _PHASE_LOG=""; _PHASE_WORK_MS=0; _PHASE_RAN_WORK=0

        _step "fast guard"
        _run true                    # the named step's own work: ~0ms
        sleep 1                      # UNNAMED work — must NOT land on "fast guard"

        _step "slow guard"
        _run sleep 1                 # the named step's own work: ~1000ms

        _step "unmeasured phase"     # no _run at all -> span fallback
        sleep 1

        TILLANDSIAS_TIMING_LOG="$log" _phase_emit_timing
    ) >/dev/null 2>&1
}

LOG="$HARNESS/timing.jsonl"
: > "$LOG"
run_sequence "$LOG"

[ -s "$LOG" ] || { bad "no timing records were emitted"; exit 1; }

field() { # <step-substring> <jq-field>
    jq -r --arg s "$1" --arg f "$2" \
        'select(.step | contains($s)) | .[$f] | tostring' "$LOG" 2>/dev/null | head -1
}
dur()  { field "$1" duration_ms; }
prov() { field "$1" phase; }

FAST_MS="$(dur fast-guard)"
SLOW_MS="$(dur slow-guard)"
UNMEASURED_MS="$(dur unmeasured-phase)"

# The point of the packet: the fast step's number is its OWN work, so the 1s of
# unnamed work that follows it must not appear here. Generous bound (400ms) so
# a loaded host cannot flake the assertion; the defect produced >1000ms.
if [ -n "$FAST_MS" ] && [ "$FAST_MS" -lt 400 ]; then
    pass "fast step excludes the unnamed work that follows it (${FAST_MS}ms)"
else
    bad "fast step absorbed adjacent unnamed work — got ${FAST_MS}ms, want <400ms (this is the 785-ibu9 defect)"
fi

# The genuinely slow step still reports its real cost — the fix must not make
# every number small, which would be the opposite failure.
if [ -n "$SLOW_MS" ] && [ "$SLOW_MS" -ge 900 ]; then
    pass "slow step still reports its own real cost (${SLOW_MS}ms)"
else
    bad "slow step under-reports — got ${SLOW_MS}ms, want >=900ms"
fi

# Provenance is explicit, never guessed.
if [ "$(prov fast-guard)" = "build" ] && [ "$(prov slow-guard)" = "build" ]; then
    pass "measured phases carry phase=build (attributable to the named step)"
else
    bad "measured phases must carry phase=build — got fast=$(prov fast-guard) slow=$(prov slow-guard)"
fi

if [ "$(prov unmeasured-phase)" = "build-span" ]; then
    pass "a phase running no _run is labelled phase=build-span, not passed off as a step cost"
else
    bad "unmeasured phase must be labelled build-span — got $(prov unmeasured-phase)"
fi

# The span fallback must still carry a real number (the wall clock), so the
# labelling does not cost the signal.
if [ -n "$UNMEASURED_MS" ] && [ "$UNMEASURED_MS" -ge 900 ]; then
    pass "span fallback still reports wall clock (${UNMEASURED_MS}ms)"
else
    bad "span fallback lost its number — got ${UNMEASURED_MS}ms, want >=900ms"
fi

# Every phase still reaches the log under the `step:` family, so cycle-metrics'
# finest-grain slowest= preference keeps seeing all of them.
n="$(grep -c '"step":"step:' "$LOG" 2>/dev/null || echo 0)"
if [ "$n" -eq 3 ]; then
    pass "all three phases emitted under the step: family (slowest= still sees them)"
else
    bad "expected 3 step: records, got $n"
fi

# ── Scenario 2: _run must not alter exit codes (682-emvg) ───────────────────
rc_probe() {
    (
        set -uo pipefail
        SCRIPT_DIR="$ROOT"; FLAG_GRAPHS=true; CYAN=""; NC=""
        _require_host_build_tools() { :; }
        # shellcheck disable=SC1090
        . "$HARNESS/tracker.sh"
        _PHASE_WORK_MS=0; _PHASE_RAN_WORK=0
        _run "$@" >/dev/null 2>&1
        echo "$?"
    )
}
[ "$(rc_probe true)" = "0" ]           && pass "_run preserves exit 0"  || bad "_run altered a success exit"
[ "$(rc_probe sh -c 'exit 7')" = "7" ] && pass "_run preserves exit 7"  || bad "_run did not propagate exit 7"

# ── Scenario 3: a broken clock degrades, never breaks ───────────────────────
# _now_ms returning garbage must not produce a negative duration or a failure.
clock_probe() {
    (
        set -uo pipefail
        SCRIPT_DIR="$ROOT"; FLAG_GRAPHS=true; CYAN=""; NC=""
        TILLANDSIAS_HOST_ID="fixturehost"
        _require_host_build_tools() { :; }
        # shellcheck disable=SC1090
        . "$HARNESS/tracker.sh"
        _now_ms() { echo 0; }          # stuck clock
        _PHASE_NAME=""; _PHASE_T0=""; _PHASE_LOG=""; _PHASE_WORK_MS=0; _PHASE_RAN_WORK=0
        _step "stuck clock phase"
        _run true
        TILLANDSIAS_TIMING_LOG="$1" _phase_emit_timing
        echo "$?"
    )
}
CLOG="$HARNESS/clock.jsonl"; : > "$CLOG"
crc="$(clock_probe "$CLOG" 2>/dev/null | tail -1)"
neg="$(grep -c '"duration_ms":-' "$CLOG" 2>/dev/null | tr -d ' \n')"
[ -n "$neg" ] || neg=0
if [ "$crc" = "0" ] && [ "$neg" -eq 0 ]; then
    pass "a stuck clock degrades to 0 and never fails the emit"
else
    bad "stuck-clock path misbehaved — rc=$crc negatives=$neg"
fi

if [ "$fail" -eq 0 ]; then
    echo "ok:build-step-timing-attribution-fixture:9"
    exit 0
fi
# Evidence on failure: a fixture that fails without showing what it saw sends
# the next reader back to reproduce it by hand.
echo "--- emitted records ---" >&2
cat "$LOG" >&2 2>/dev/null || true
echo "fail: build-step-timing-attribution scenarios failed"
exit 1
