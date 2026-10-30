#!/usr/bin/env bash
# @trace order:1916-tsel, order:1204-3s2s, spec:ci-release
#
# Fixture: the gate's shared-timing-log leak check blames a step ONLY for
# records its own gate wrote, so two gates on one host stop evicting each
# other's PRs (coordinator 2026-10-29: two land-queue evictions).
#
# Two CONCURRENT writers append to one scratch log (never the host's real
# /tmp/tillandsias-timing.jsonl):
#   gate A runs step "clean"  (writes nothing)   and step "leaky" (writes)
#   gate B, a different run id, writes records the whole time.
#   1 the clean step is not named although B grew the file during it
#   2 the leaky step IS named (ours>0) although B wrote too
#   3 a record with no run id is unattributed, never ours
#   4 build.sh's step loop hands the helper its run id (wiring)
# FAILS ON THE PRE-FIX TREE: the helper does not exist there, and the old
# growth check names the clean step.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$ROOT/scripts/gate-step-metrics-attribution.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok:arm-$1"; }
bad() { fail=$((fail + 1)); echo "FAIL:arm-$1 — $2"; }
if [ ! -f "$H" ]; then
    echo "FAIL:gate-step-metrics-attribution:helper-missing — the leak check still attributes by file growth"
    exit 1
fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gsma-fx.XXXXXX")" || exit 1
B_PID=""
trap '[ -n "$B_PID" ] && kill "$B_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
LOG="$TMP/shared-timing.jsonl"
rec() { printf '{"step":"%s","duration_ms":1%s}\n' "$1" "${2:+,\"run_id\":\"$2\"}" >> "$LOG"; }

# gate B: a concurrent writer for the whole fixture
( for _ in $(seq 1 400); do rec other-gate gate-B; sleep 0.005; done ) </dev/null >/dev/null 2>&1 &
B_PID=$!
rec warmup gate-B

# gate A, step "clean": writes nothing, while B keeps writing
before="$(wc -l < "$LOG")"; sleep 0.3
v1="$(bash "$H" "$LOG" "$before" gate-A)"
grew=$(( $(wc -l < "$LOG") - before ))
if [ "$grew" -gt 0 ] && [ "$v1" = "${v1#ours=0 }" ]; then bad 1 "premise or verdict wrong: grew=$grew [$v1]"
elif [ "$grew" -gt 0 ]; then ok 1; else bad 1 "premise: gate B did not write during the clean step, so this arm proves nothing"; fi

# gate A, step "leaky": writes two records stamped with A's run id
before="$(wc -l < "$LOG")"
rec leaky gate-A; sleep 0.1; rec leaky gate-A; sleep 0.1
v2="$(bash "$H" "$LOG" "$before" gate-A)"
case "$v2" in "ours=2 foreign="*) ok 2 ;; *) bad 2 "the leaking step was not named with its 2 records: [$v2]" ;; esac

# an id-less record is never blamed on the step
before="$(wc -l < "$LOG")"; rec anonymous ""
v3="$(bash "$H" "$LOG" "$before" gate-A)"
case "$v3" in "ours=0 "*"unattributed="[1-9]*) ok 3 ;; *) bad 3 "an id-less record was not reported as unattributed: [$v3]" ;; esac

if grep -qF 'gate-step-metrics-attribution.sh" "$_metrics_shared" "${_metrics_shared_before:-0}" "${TILLANDSIAS_TIMING_RUN_ID:-none}"' "$ROOT/build.sh"; then ok 4
else bad 4 "build.sh's step loop does not attribute shared-log records by its run id"; fi

if [ "$fail" -gt 0 ]; then echo "FAIL:gate-step-metrics-attribution:$fail-of-$((pass + fail))"; exit 1; fi
echo "ok:gate-step-metrics-attribution:$pass"
