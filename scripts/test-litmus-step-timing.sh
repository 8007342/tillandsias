#!/usr/bin/env bash
# @trace order:1233-jqp4
#
# The litmus runner's PER-STEP duration records (.cache/metrics/litmus-step-timing.jsonl).
# A budget is set per step; the per-test records only bound a step from above,
# which left 17 tests on yoga unsettled. These arms pin that the step records
# exist, are one per EXECUTED step, are valid JSON, and are never fabricated.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R="$ROOT/scripts/run-litmus-test.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/litmus-step-timing.XXXXXX")"
trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# The helper, extracted from the runner itself so the arms test the shipped
# code, not a copy that could drift.
fn="$(sed -n '/^_lt_step_record() {/,/^}/p' "$R")"
[ -n "$fn" ] || { echo "FAIL premise: _lt_step_record not found in $R"; exit 1; }

# Resolve THIS checkout's plan binary before anything else and hand it to the
# runner explicitly: without it, a regime with no CARGO_TARGET_DIR and no
# TILLANDSIAS_PLAN_BIN (the darwin gate; preflight-fixtures-default-target)
# makes the runner refuse to execute steps (relay-fix, macuahuitl 2026-09-27;
# the same remedy as 1427-utmy, 84f37ff24).
. "$ROOT/scripts/plan-binary-probe.sh"
PB="$(cd "$ROOT" && resolve_plan_binary 2>/dev/null)" || PB=""
case "$PB" in ./*) PB="$ROOT/${PB#./}" ;; esac

# 1. A real run: one record per EXECUTED step, each valid JSON with the fields.
log="$work/steps.jsonl"
out="$(TILLANDSIAS_PLAN_BIN="$PB" LITMUS_STEP_TIMING_LOG="$log" "$R" binary-signing --compact 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
steps="$(grep -c '\[STEP [0-9]*/[0-9]*\]' <<<"$out")"
recs="$( [ -f "$log" ] && grep -c . "$log" || echo 0)"
if [ "$steps" -lt 1 ]; then
    bad "premise: the run executed no steps (runner output: $(tail -1 <<<"$out"))"
elif [ "$recs" != "$steps" ]; then
    bad "one record per executed step: $steps steps ran, $recs records written"
else
    ok "one record per executed step ($steps)"
fi
# Every record, not the last one: `-e` decides on the LAST value only, so a
# malformed record anywhere but the end passed the earlier `jq -e` form.
# Instead print each record that FAILS the shape and require none. Read with
# the plan binary's json get, not jq (1375-tsfu ratchet).
if [ -z "$PB" ]; then
    bad "premise: no plan binary to validate the records with"
elif [ -f "$log" ]; then
    badrecs="$("$PB" json get -c 'select((has("test") and has("step") and has("budget_ms") and has("duration_ms") and has("exit") and (.duration_ms >= 0)) | not)' "$log" 2>&1)"; jrc=$?
    if [ "$jrc" -ne 0 ]; then
        bad "json get could not read the records (rc=$jrc): $(head -c 120 <<<"$badrecs")"
    elif [ -n "$badrecs" ]; then
        bad "a record lacks a field or has a negative duration: $(head -1 <<<"$badrecs")"
    else
        ok "every record (not just the last) is valid JSON with test/step/budget_ms/duration_ms/exit"
    fi
fi

# 2. A stubbed clock or a missing start time writes NOTHING, never a fabricated 0.
log2="$work/stub.jsonl"
( eval "$fn"; timing_now_ms() { echo 0; }; LITMUS_STEP_TIMING_LOG="$log2"
  _lt_step_record x.yaml 1 3000 1234 0 )
( eval "$fn"; timing_now_ms() { echo 5000; }; LITMUS_STEP_TIMING_LOG="$log2"
  _lt_step_record x.yaml 1 3000 0 0 )
[ ! -s "$log2" ] && ok "a stubbed clock or a zero start writes no record" \
    || bad "a record was fabricated: $(cat "$log2")"

# 3. NEGATIVE CONTROL for arm 2: a real clock and start DO write, with the
#    difference as the duration — otherwise arm 2 passes on a helper that never writes.
log3="$work/real.jsonl"
( eval "$fn"; timing_now_ms() { echo 5000; }; LITMUS_STEP_TIMING_LOG="$log3"
  _lt_step_record litmus-x.yaml 2 3000 1234 7 )
case "$(cat "$log3" 2>/dev/null)" in
    *'"test":"litmus-x","step":2,"budget_ms":3000,"duration_ms":3766,"exit":7}'*) ok "a real clock writes the measured duration" ;;
    *) bad "expected duration 3766 for litmus-x step 2, got: $(cat "$log3" 2>/dev/null)" ;;
esac

# 4. An unwritable log is harmless: rc 0, no output on stdout.
o4="$( eval "$fn"; timing_now_ms() { echo 5000; }; LITMUS_STEP_TIMING_LOG=/proc/nonexistent/x.jsonl
       _lt_step_record x.yaml 1 3000 1234 0; echo "rc=$?" )"
[ "$o4" = "rc=0" ] && ok "an unwritable log path changes nothing (rc 0, silent)" \
    || bad "unwritable log path leaked: $o4"

if [ "$fail" = 0 ]; then echo "ok:litmus-step-timing:$pass arms"; exit 0; fi
echo "FAIL:litmus-step-timing:$fail failed"; exit 1
