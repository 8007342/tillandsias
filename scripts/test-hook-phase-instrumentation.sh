#!/usr/bin/env bash
# @trace order:1064-5hv2
#
# Pin: the pre-commit hook can report its own per-phase timings, and the drift
# warning names the MULTIPLE rather than making the reader divide.
#
# WHY THIS EXISTS. Re-measuring 734-sjb3 needed per-phase numbers and the
# shipped hook would not produce them, so macbookair made a throwaway copy with
# the warning condition forced true — and hours later, on a different host, so
# did I, independently, for the same reason. When two hosts have to DEFEAT a
# signal to read it, the signal is set wrong. This fixture pins the affordance
# that removes the need for those copies.
#
# WHAT IT DELIBERATELY DOES NOT PIN: the 1x threshold. The warning still fires
# only above 4x, so the blind band from 1x to 4x is still open and 1064-5hv2 is
# still open with it. Closing it changes warning volume on every host and every
# commit, and a signal that fires constantly is ignored — this packet's own
# failure mode inverted. That change waits on a second host's volumes, which is
# what the instrumentation exists to collect.
#
# Arms 3 and 4 run a COPY of the hook with an injected slow phase. Stated
# plainly because a fixture that edits a copy is weaker than one driving the
# real thing: the real hook has no phase slow enough to trip a warning on a
# healthy tree, and making one would mean slowing a real commit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/scripts/hooks/pre-commit-openspec.sh"
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/hook-instr.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# ── 1. SILENT BY DEFAULT ───────────────────────────────────────────────────
# The instrumentation must cost a normal commit nothing, or it will be the next
# thing someone turns off.
out="$(cd "$ROOT" && bash "$HOOK" 2>&1)"
case "$out" in
    *"OpenSpec phase:"*) bad "the per-phase table printed without being asked for" ;;
    *) ok "instrumentation is silent unless requested" ;;
esac

# ── 2. ON REQUEST IT REPORTS EVERY PHASE, WITH ITS MULTIPLE ────────────────
out="$(cd "$ROOT" && TILLANDSIAS_HOOK_PHASE_TIMING=1 bash "$HOOK" 2>&1)"
n="$(printf '%s\n' "$out" | grep -c 'OpenSpec phase:' || true)"
if [ "${n:-0}" -ge 4 ]; then
    ok "every phase is reported when asked ($n phases)"
else
    bad "only ${n:-0} phases reported; a partial table is what sent two hosts to copy the hook"
fi
# NON-VACUITY: a table of names with no numbers would satisfy the count above.
if printf '%s\n' "$out" | grep -qE 'OpenSpec phase:.*[0-9]+ms.*budget.*[0-9]+\.[0-9]+x'; then
    ok "the reported lines carry elapsed, budget and the multiple"
else
    bad "the table has no usable numbers"
    printf '%s\n' "$out" | grep 'OpenSpec phase:' | head -3 | sed 's/^/      /' >&2
fi

# ── 3. THE DRIFT WARNING NAMES THE MULTIPLE ────────────────────────────────
# A copy with an injected phase, because no real phase is slow enough to trip
# the warning on a healthy tree.
cp "$HOOK" "$W/hook.sh"
# In-place edit via awk to a sibling file, then move. Two injections:
# a phase with a 1 ms budget, and a call to it before ghost_check. The
# `run_phase` injection is FIRST-OCCURRENCE ONLY (the `done` flag), matching
# the count=1 it replaces — injecting at every call site would run the slow
# phase repeatedly and make the timing assertion depend on how many there are.
awk '
    index($0, "        zero_trace_check)       echo 2500 ;;") {
        print; print "        _fixture_slow_phase)    echo 1 ;;"; next
    }
    !done && index($0, "run_phase ghost_check") {
        print "_fixture_slow_phase() { sleep 0.05; }"
        print "run_phase _fixture_slow_phase"
        done = 1
    }
    { print }
' "$W/hook.sh" > "$W/hook.next" && mv "$W/hook.next" "$W/hook.sh"
out="$(cd "$ROOT" && bash "$W/hook.sh" 2>&1)"
warn="$(printf '%s\n' "$out" | grep '_fixture_slow_phase took' || true)"
if [ -n "$warn" ]; then
    ok "an over-budget phase still warns"
else
    bad "the injected slow phase produced no warning; arm 4 would prove nothing"
fi
case "$warn" in
    *"x its"*) ok "the warning names the multiple, not just the two numbers" ;;
    *) bad "the warning does not name the multiple: ${warn:-<none>}" ;;
esac

# ── 4. THE BLIND BAND IS STILL OPEN, and this asserts it ON PURPOSE ────────
# Between 1x and 4x nothing is said. Pinning the CURRENT behaviour means the
# day someone closes the band, this arm fails and forces them to read
# 1064-5hv2 and the volume evidence rather than flipping a threshold quietly.
# Widen the budget so the same injected phase is inside 4x but over 1x: the
# blind band. Exact-line swap, same reason as above.
awk '
    index($0, "_fixture_slow_phase)    echo 1 ;;") {
        sub(/echo 1 ;;/, "echo 30 ;;"); print; next
    }
    { print }
' "$W/hook.sh" > "$W/hook.next" && mv "$W/hook.next" "$W/hook.sh"
out="$(cd "$ROOT" && bash "$W/hook.sh" 2>&1)"
if printf '%s\n' "$out" | grep -q '_fixture_slow_phase took'; then
    bad "a phase between 1x and 4x now warns — the band is closed; if that is intended, update this arm and 1064-5hv2 together with the two-host volume evidence"
else
    ok "the 1x-to-4x blind band is still open (1064-5hv2 remains open with it)"
fi

echo "hook-phase-instrumentation: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
