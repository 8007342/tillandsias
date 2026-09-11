#!/usr/bin/env bash
# ORDER 1026-ps4n. A timing record must survive the death of the shell that was
# measuring it — or, failing that, the LOG must say so rather than fall silent.
#
# THE INCIDENT THIS PINS. On pirria 2026-09-04 the agent harness killed the
# smoke's supervising shell mid-forge-lane for host memory pressure. No kernel
# oom-kill; all six enclave containers survived and were healthy 56 minutes
# later; only the wrapper died. `timing_emit` runs after the step, in that
# shell, so no record was written and the log was SILENT about a step that had
# actually run — indistinguishable from one that never started. The floor's
# largest measurement is the one least likely to be captured.
#
# WHAT IS AND IS NOT ASSERTED HERE. This does not invent the missing number: a
# reaped record carries a LOWER BOUND, because the true end time was never
# observed. What it asserts is that absence becomes self-describing, and — the
# arm that matters most — that a lost record can never be mistaken for a real
# one, because it is emitted under a DIFFERENT STEP NAME. The recurrence rung
# groups by step, so a lower bound landing in the real step's average would
# quietly corrupt exactly the decision (what to memoise) the log exists to
# inform. That is the failure this suite exists to prevent, so it has both a
# positive arm and a mutation control.
#
# Hermetic: a scratch stamp dir and a scratch log, no real smoke, no containers.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
W="$(mktemp -d "${TMPDIR:-/tmp}/timing-supervisor.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1" >&2; fail=$((fail+1)); }

export TILLANDSIAS_TIMING_STAMP_DIR="$W/pending"
export TILLANDSIAS_TIMING_LOG="$W/timing.jsonl"
# shellcheck source=scripts/timing-log.sh
. "$ROOT/scripts/timing-log.sh"

steps() { [ -f "$TILLANDSIAS_TIMING_LOG" ] && grep -c . "$TILLANDSIAS_TIMING_LOG" || echo 0; }
field() { # field <step-substring> <json-key>
    grep -F "\"step\":\"$1\"" "$TILLANDSIAS_TIMING_LOG" 2>/dev/null | tail -1 |
        sed -n "s/.*\"$2\":\([^,}]*\).*/\1/p"
}

# ── 1. A LIVE writer is never reaped. A lane still running under a healthy
#      supervisor must not have its stamp collected out from under it — that
#      would manufacture a lost-supervisor record for a step that is fine.
timing_begin probe-live smoke
timing_reap
[ "$(steps)" = 0 ] && ok "a live writer's stamp is not reaped" \
    || bad "a live writer was reaped: $(cat "$TILLANDSIAS_TIMING_LOG")"
[ -f "$TILLANDSIAS_TIMING_STAMP_DIR/probe-live.stamp" ] \
    && ok "the live stamp is left in place" || bad "the live stamp was removed"
rm -f "$TILLANDSIAS_TIMING_STAMP_DIR/probe-live.stamp"

# ── 2. A DEAD writer's stamp becomes a named-cause record. The stamp is written
#      by a subshell that then exits, which is what a killed wrapper leaves.
bash -c ". '$ROOT/scripts/timing-log.sh'; timing_begin probe-lost smoke"
[ -f "$TILLANDSIAS_TIMING_STAMP_DIR/probe-lost.stamp" ] \
    && ok "a stamp survives the shell that wrote it" || bad "no stamp after begin"
timing_reap
got="$(field probe-lost-supervisor-lost step 2>/dev/null)"
grep -qF '"step":"probe-lost-supervisor-lost"' "$TILLANDSIAS_TIMING_LOG" 2>/dev/null \
    && ok "a dead writer yields <step>-supervisor-lost, not silence" \
    || bad "no supervisor-lost record: $(cat "$TILLANDSIAS_TIMING_LOG" 2>/dev/null)"
[ ! -f "$TILLANDSIAS_TIMING_STAMP_DIR/probe-lost.stamp" ] \
    && ok "the reaped stamp is cleared so it reports once" || bad "stamp survived the reap"

# ── 3. THE NAME IS THE SAFETY PROPERTY. The lost record must NOT be filed under
#      the real step name, or its lower-bound duration would be averaged into
#      the timings that decide what to memoise.
grep -qF '"step":"probe-lost"' "$TILLANDSIAS_TIMING_LOG" 2>/dev/null \
    && bad "a lost record was filed under the REAL step name — it will pollute the average" \
    || ok "no record under the real step name: the lower bound cannot be averaged in"

# ── 4. A CLEAN completion emits the real record and leaves nothing to reap.
before="$(steps)"
t0="$(timing_now_ms)"
timing_begin probe-clean smoke
timing_commit probe-clean smoke "$t0" 0
grep -qF '"step":"probe-clean"' "$TILLANDSIAS_TIMING_LOG" \
    && ok "commit emits the real record" || bad "commit emitted nothing"
[ ! -f "$TILLANDSIAS_TIMING_STAMP_DIR/probe-clean.stamp" ] \
    && ok "commit clears its own stamp" || bad "commit left a stamp behind"
after_commit="$(steps)"
timing_reap
[ "$(steps)" = "$after_commit" ] \
    && ok "reap after a clean commit emits nothing" || bad "reap double-reported a completed step"
[ "$(field probe-clean exit)" = 0 ] \
    && ok "the clean record carries the step's own exit code" \
    || bad "clean record exit — want 0, got $(field probe-clean exit)"

# ── 5. MUTATION CONTROL: without the stamp, a killed step leaves SILENCE. This
#      is the pre-fix behaviour and the reason the packet exists; if this arm
#      ever passes-by-accident the suite has stopped testing anything.
rm -rf "$TILLANDSIAS_TIMING_STAMP_DIR"; mkdir -p "$TILLANDSIAS_TIMING_STAMP_DIR"
before="$(steps)"
bash -c ". '$ROOT/scripts/timing-log.sh'; t=\$(timing_now_ms); exit 0"   # dies before emitting
timing_reap
[ "$(steps)" = "$before" ] \
    && ok "MUTATION: a step that never stamped leaves silence — the stamp is what buys the record" \
    || bad "mutation control produced a record from nothing"

echo "timing-supervisor-lost: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
