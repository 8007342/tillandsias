#!/usr/bin/env bash
# @trace spec:methodology-accountability
#
# test-timing-clock-resolution.sh — order 1279-a7b6.
#
# WHAT IT PROTECTS. `timing_now_ms` used to source its clock only from
# `date +%s%3N`, which is GNU-only. BSD date does not REJECT %3N — it emits the
# literal characters (`date +%s%3N` -> `17898506753N`), so the non-digit guard
# fired and the fallback stapled three zeros onto whole seconds. Every step
# faster than a second then recorded `duration_ms: 0`.
#
# WHY 0 IS WORSE THAN A WRONG NUMBER: `timing_emit` ALREADY treats a `_t0` of 0
# as "the path-skew stub ran, there was no measurement" (693-tf79). So on a
# BSD-date host a REAL sub-second measurement and an ABSENT instrument emitted
# the same value, and the exit code did not separate them either — both 0.
#
# THE NEGATIVE CONTROL IS NOT DECORATION. macneo's contrast run produced
# `duration_ms:42000` and `duration_ms:0` in ONE run on ONE clock, which is the
# only reason we know the clock is sound and only its RESOLUTION was wrong. A
# "fix" that improved sub-second records while degrading multi-second ones would
# satisfy a one-armed test and be measuring something else, so arm 2 pins it.
#
# ARM 3 EXISTS BECAUSE THE OBVIOUS WRONG FIX IS TO DELETE THE SKIP. Removing the
# `_t0 -eq 0` guard in timing_emit would "stop losing" sub-second records — and
# would let absolute epoch-ms values through as ~56-year durations, which is
# what that guard was written for. The skip must survive the fix.
#
# GRAMMAR — exactly one line:
#   ^(ok:timing-clock-resolution:[0-9]+|violation:timing-clock-resolution:.*|unsupported:timing-clock-resolution:.*)$
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/timing-log.sh"
[ -r "$LIB" ] || { echo "violation:timing-clock-resolution:no-timing-log-sh"; exit 1; }

pass=0
fail=0
note() { printf '  %s\n' "$1" >&2; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/timing-clock-res.XXXXXX")" || {
    echo "violation:timing-clock-resolution:cannot-mktemp"; exit 1; }
trap 'rm -rf "$TMPD"' EXIT

LOG="$TMPD/timing.jsonl"

# One subshell drives all three cases so they share a clock, exactly as the
# contrast run that motivated this did.
TILLANDSIAS_TIMING_LOG="$LOG" bash -c '
    . "'"$LIB"'"
    t0="$(timing_now_ms)"; sleep 0.25; timing_emit fx-sub   fx "$t0" 0
    t1="$(timing_now_ms)"; sleep 2;    timing_emit fx-multi fx "$t1" 0
    timing_emit fx-stub fx 0 0
    printf "%s\n" "$(timing_clock_resolution)" > "'"$TMPD"'/res"
' >/dev/null 2>&1

[ -s "$LOG" ] || { echo "violation:timing-clock-resolution:no-records-emitted"; exit 1; }

_dur() { sed -n "s/.*\"step\":\"$1\".*\"duration_ms\":\([0-9]*\).*/\1/p" "$LOG" | head -1; }

# ── ARM 1: a sub-second step must not record 0 ──────────────────────────────
sub="$(_dur fx-sub)"
if [ -n "$sub" ] && [ "$sub" -gt 0 ] 2>/dev/null; then
    note "ok   sub-second step recorded ${sub}ms, not the stub sentinel"
    pass=$((pass+1))
else
    note "FAIL sub-second step recorded '${sub:-<absent>}' — 0 is indistinguishable from 'no instrument'"
    fail=$((fail+1))
fi

# ── ARM 2 (NEGATIVE CONTROL): a multi-second step keeps its real value ──────
multi="$(_dur fx-multi)"
if [ -n "$multi" ] && [ "$multi" -ge 1500 ] 2>/dev/null && [ "$multi" -lt 10000 ] 2>/dev/null; then
    note "ok   multi-second step still recorded ${multi}ms"
    pass=$((pass+1))
else
    note "FAIL multi-second step recorded '${multi:-<absent>}' — the clock itself regressed"
    fail=$((fail+1))
fi

# ── ARM 3: the path-skew skip must survive ──────────────────────────────────
if grep -q '"step":"fx-stub"' "$LOG"; then
    note "FAIL a _t0=0 record was emitted — the 693-tf79 skip was removed"
    fail=$((fail+1))
else
    note "ok   a _t0=0 record is still skipped (693-tf79 intact)"
    pass=$((pass+1))
fi

# ── ARM 4: the resolution is reported, and reported honestly ────────────────
res="$(tr -d '\n' < "$TMPD/res" 2>/dev/null)"
case "$res" in
    ms|s)
        note "ok   timing_clock_resolution reports '$res'"
        pass=$((pass+1))
        ;;
    *)
        # An empty answer is the specific defect this arm exists for: a first
        # cut recorded the winning arm in a global, and since every caller
        # invokes timing_now_ms through $(...) — a subshell — the value was
        # discarded and the reporter answered empty forever.
        note "FAIL timing_clock_resolution returned '${res:-<empty>}' — a subshell-scoped global cannot survive \$( )"
        fail=$((fail+1))
        ;;
esac

if [ "$fail" -ne 0 ]; then
    echo "violation:timing-clock-resolution:$fail-arm(s)-failed"
    exit 1
fi
echo "ok:timing-clock-resolution:$pass"
