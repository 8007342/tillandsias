#!/usr/bin/env bash
# @trace order:1233-jqp4
#
# 1233-jqp4 criterion 4, the NEGATIVE CONTROL for every budget change: making
# room for a slow CORRECT step must not make room for a BROKEN one. Through the
# REAL runner, in a scratch project root (956-llei's construction):
#   arm 1 — a HUNG producer is killed at its budget AND the test's verdict is
#           red (a kill that the verdict ignored would pass a hang as green);
#   arm 2 — a WRONG producer (exits 0, prints the wrong answer) under a
#           GENEROUS 300 s budget is red, and red FAST — the budget is a
#           ceiling on waiting, not a grace period for a wrong answer;
#   arm 3 — POSITIVE CONTROL: the right answer under the same setup is green,
#           so arms 1-2 cannot pass on a runner that fails everything.
set -uo pipefail
export TILLANDSIAS_TIMING_LOG="${TILLANDSIAS_TIMING_LOG:-${TMPDIR:-/tmp}/tillandsias-timing-FIXTURES.jsonl}"
export LITMUS_STEP_TIMING_LOG="${TMPDIR:-/tmp}/litmus-step-timing-FIXTURES.jsonl"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/litmus-budget-neg.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/openspec/litmus-tests" "$tmp/methodology" "$tmp/target"
ln -s "$ROOT/scripts" "$tmp/scripts"
ln -s "$ROOT/methodology/litmus.yaml" "$tmp/methodology/litmus.yaml"
slug="budget-negative-control-probe"
name="litmus:${slug}"
cat > "$tmp/openspec/litmus-bindings.yaml" <<EOB
specs:
  - spec_id: ${slug}
    status: active
    litmus_tests:
      - ${name}
EOB
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN_BIN="$(cd "$ROOT" && resolve_plan_binary)" || { echo "FAIL premise: no runnable tillandsias-plan"; exit 1; }
case "$PLAN_BIN" in /*) ;; *) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac

write_probe() { # <command> <timeout_ms> <expected>
    cat > "$tmp/openspec/litmus-tests/litmus-${slug}.yaml" <<EOP
# fixture-only probe (1233-jqp4); lives only in a temp root.
name: ${name}
spec: ${slug}
phase: pre-build
size: instant
severity: low
description: >
  Fixture probe for the budget negative control.
critical_path:
  - step: "the probe step"
    command: "$1"
    timeout_ms: $2
    expected_behavior: "$3"
EOP
}
run_probe() { # prints runner output; sets RC and ELAPSED
    local s; s=$(date +%s)
    OUT="$(cd "$tmp" && TILLANDSIAS_PLAN_BIN="$PLAN_BIN" bash "$tmp/scripts/run-litmus-test.sh" "$slug" --phase pre-build 2>&1)"; RC=$?
    ELAPSED=$(( $(date +%s) - s ))
    OUT="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$OUT")"
}
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
red_verdict() { grep -qE "\[FAIL\] spec=${slug}" <<<"$OUT"; }

# 3 first: the positive control, so a red below means something.
write_probe "echo right-answer" 10000 "right-answer"; run_probe
if [ "$RC" -eq 0 ] && ! red_verdict && grep -qE "\[PASS\]|passed=1" <<<"$OUT"; then ok "positive control: the right answer is green (rc=$RC)"
else bad "positive control: the right answer did not pass (rc=$RC): $(tail -2 <<<"$OUT" | tr '\n' ' ')"; fi

write_probe "sleep 30; echo right-answer" 2000 "right-answer"; run_probe
if grep -q 'TIMEOUT' <<<"$OUT" && red_verdict && [ "$RC" -ne 0 ] && [ "$ELAPSED" -lt 25 ]; then ok "a hung producer is killed at its budget and the verdict is red (rc=$RC, ${ELAPSED}s)"
else bad "hung producer: TIMEOUT=$(grep -c TIMEOUT <<<"$OUT") red=$(red_verdict && echo y || echo n) rc=$RC elapsed=${ELAPSED}s"; fi

write_probe "echo wrong-answer" 300000 "right-answer"; run_probe
if red_verdict && [ "$RC" -ne 0 ] && [ "$ELAPSED" -lt 60 ]; then ok "a wrong producer under a 300 s budget is red, and fast (rc=$RC, ${ELAPSED}s)"
else bad "wrong producer: red=$(red_verdict && echo y || echo n) rc=$RC elapsed=${ELAPSED}s"; fi

if [ "$fail" = 0 ]; then echo "ok:litmus-budget-negative-control:$pass arms"; exit 0; fi
echo "FAIL:litmus-budget-negative-control:$fail failed"; exit 1
