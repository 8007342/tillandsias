#!/usr/bin/env bash
# @trace spec:spec-traceability, order:2150-3j97
#
# test-litmus-timeout-retry.sh — priority:build-speed. A litmus step killed by
# its OWN timeout with no output is re-run once and announced as
# flaky:<test>#<step>; an assertion red is never re-run. RC attempt 4 failed
# only on two such kills on a loaded host.
#
# Arms, each through a copy of scripts/run-litmus-test.sh in a scratch project
# and a counter file that records every execution of the step:
#   1  times out silently once, then passes   -> PASS, flaky: line, 2 runs
#   2  NEGATIVE CONTROL: assertion red (exit 1) -> FAIL, no flaky:, 1 run
#   3  prints output, then times out          -> FAIL, no flaky:, 1 run
#   4  times out silently twice               -> FAIL, flaky: once, 2 runs
#   5  LITMUS_TIMEOUT_RETRY=0                  -> FAIL, no flaky:, 1 run
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/litmus-timeout-retry.XXXXXX")"
W="$(cd "$W" && pwd -P)"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(cd "$ROOT" && resolve_plan_binary)" || { echo "FAIL: no runnable plan binary" >&2; exit 1; }
case "$PLAN" in /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac
unset PROJECT_ROOT TILLANDSIAS_REPO_ROOT TILLANDSIAS_POLICY_REGIME TILLANDSIAS_FIXTURE_SCOPE TILLANDSIAS_FIXTURE_GIT_DIRS
export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = t\n\temail = t@example.invalid\n' >"$GIT_CONFIG_GLOBAL"

# The probe's name is built, so check-litmus-pin-claims does not read a
# fixture-local name as a claim on a real litmus test.
LIT="litmus"
P="$W/project"
git init -q "$P"
cp -R "$ROOT/scripts" "$P/scripts"
mkdir -p "$P/lt" "$P/scratch"
cat >"$P/bindings.yaml" <<YAML
version: '1.0'
description: fixture for 2150-3j97
specs:
- spec_id: spec-traceability
  status: active
  ${LIT}_tests:
  - ${LIT}:retry-probe
  coverage_ratio: 100
  last_verified: '2026-11-21'
YAML
CNT="$P/scratch/count"
# probe <command> [env...] -> the runner's output; the counter is reset first.
probe() {
    local cmd="$1"; shift
    : >"$CNT"
    cat >"$P/lt/${LIT}-retry-probe.yaml" <<YAML
name: ${LIT}:retry-probe
spec: spec-traceability
phase: pre-build
severity: high
size: instant
description: >
  probe for 2150-3j97
critical_path:
  - step: "probe"
    command: "$cmd"
    timeout_ms: 2000
    expected_behavior: "probe-done"
YAML
    (cd "$P" && env "$@" TILLANDSIAS_PLAN_BIN="$PLAN" TILLANDSIAS_LITMUS_BINDINGS="$P/bindings.yaml" \
        TILLANDSIAS_LITMUS_TESTS_DIR="$P/lt" timeout 120 bash scripts/run-litmus-test.sh spec-traceability \
        --phase pre-build --size instant --compact 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
}
runs() { grep -c . "$CNT" 2>/dev/null || echo 0; }
# Each command appends one line per execution, then behaves per its arm.
TICK="echo run >> $CNT"

out="$(probe "$TICK; if [ \$(grep -c . $CNT) -ge 2 ]; then echo probe-done; else sleep 30; fi")"
if grep -qE 'Status: \[PASS\]' <<<"$out" && grep -q 'flaky:litmus-retry-probe#1 timed out' <<<"$out" && [ "$(runs)" -eq 2 ]; then
    ok "arm 1: a silent timeout is re-run once, announced flaky:<test>#<step>, and the pass stands"
else
    bad "arm 1: runs=$(runs) [$(tail -n 12 <<<"$out")]"
fi

out="$(probe "$TICK; echo wrong; exit 1")"
if grep -qE 'Status: \[FAIL\]' <<<"$out" && ! grep -q 'flaky:' <<<"$out" && [ "$(runs)" -eq 1 ]; then
    ok "arm 2 (negative control): an assertion red is never re-run and is not called flaky"
else
    bad "arm 2: runs=$(runs) [$(tail -n 12 <<<"$out")]"
fi

out="$(probe "$TICK; echo partial; sleep 30")"
if grep -qE 'Status: \[FAIL\]' <<<"$out" && ! grep -q 'flaky:' <<<"$out" && [ "$(runs)" -eq 1 ]; then
    ok "arm 3: a step that printed output before its timeout is not re-run"
else
    bad "arm 3: runs=$(runs) [$(tail -n 12 <<<"$out")]"
fi

out="$(probe "$TICK; sleep 30")"
if grep -qE 'Status: \[FAIL\]' <<<"$out" && [ "$(grep -c 'flaky:' <<<"$out")" -eq 1 ] && [ "$(runs)" -eq 2 ]; then
    ok "arm 4: a step that times out twice stays red after exactly one re-run"
else
    bad "arm 4: runs=$(runs) [$(tail -n 12 <<<"$out")]"
fi

out="$(probe "$TICK; sleep 30" LITMUS_TIMEOUT_RETRY=0)"
if grep -qE 'Status: \[FAIL\]' <<<"$out" && ! grep -q 'flaky:' <<<"$out" && [ "$(runs)" -eq 1 ]; then
    ok "arm 5: LITMUS_TIMEOUT_RETRY=0 disables the re-run"
else
    bad "arm 5: runs=$(runs) [$(tail -n 12 <<<"$out")]"
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: litmus-timeout-retry $pass/$pass (2150-3j97)"
    exit 0
fi
echo "FAIL: litmus-timeout-retry $pass passed, $fail failed (2150-3j97)"
exit 1
