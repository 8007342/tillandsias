#!/usr/bin/env bash
# ORDER 956-llei. A litmus test whose phase is `retired` runs ONLY under an
# explicit `--phase retired`. The runner's default phase filter is "all", and
# --diff-scope fails CLOSED into that default, so an escalated scoped run used
# to execute every retired fixture in the corpus.
#
# Two arms, each run THROUGH THE REAL RUNNER in a temp root (the runner derives
# PROJECT_ROOT from its own path; a symlinked scripts/ dir makes the temp root
# the project). The retired probe's step FAILS LOUDLY if it ever executes, so
# "skipped" and "ran" cannot be confused:
#   1. no --phase (the "all" default): the retired probe is reported SKIP with
#      the retired reason, the live probe runs, the suite PASSES.
#   2. --phase retired: the retired probe EXECUTES and the suite FAILS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Name the reader explicitly. The runner reads its OWN metadata (bindings, probe
# yaml) through the compiled tillandsias-plan when one resolves, and falls back
# to yq/grep otherwise (746-htj9). PROJECT_ROOT here is the TEMP root, whose
# target/ is empty, so the resolve finds nothing and the fallback needs yq on
# PATH — which no macOS host has. Without the override both arms failed as
# `No litmus tests bound to spec`, for a reason unrelated to phase filtering.
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN_BIN="$(cd "$ROOT" && resolve_plan_binary)" || {
    echo "SKIP: no runnable tillandsias-plan to read the fixture's own metadata (956-llei)"
    exit 0
}
# The probe prints a path relative to the checkout; the arms cd into the temp
# root, so absolutize it here or the override names nothing.
case "$PLAN_BIN" in /*) ;; *) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac

tmp="$(mktemp -d "${TMPDIR:-/tmp}/litmus-retired-phase.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/openspec/litmus-tests" "$tmp/methodology" "$tmp/target"
ln -s "$ROOT/scripts" "$tmp/scripts"
ln -s "$ROOT/methodology/litmus.yaml" "$tmp/methodology/litmus.yaml"

# Names are COMPOSED, never literal `litmus:<slug>` tokens: the 721-77yu pin
# checker would read a literal in a script as a claim on a suite test, and
# these probes exist only in this temp root.
spec_slug="retired-phase-probe"
live_slug="retired-phase-live"; live_name="litmus:${live_slug}"
retired_slug="retired-phase-retired"; retired_name="litmus:${retired_slug}"

cat > "$tmp/openspec/litmus-bindings.yaml" <<EOF
specs:
  - spec_id: ${spec_slug}
    status: active
    litmus_tests:
      - ${live_name}
      - ${retired_name}
EOF

cat > "$tmp/openspec/litmus-tests/litmus-${live_slug}.yaml" <<EOF
# fixture-only probe (956-llei): a live pre-build test that passes.
name: ${live_name}
spec: ${spec_slug}
phase: pre-build
size: instant
severity: low
description: >
  Fixture probe: live phase, passes.
critical_path:
  - step: "live step passes"
    command: "echo ok: live"
    timeout_ms: 5000
    expected_behavior: "ok: live"
EOF

cat > "$tmp/openspec/litmus-tests/litmus-${retired_slug}.yaml" <<EOF
# fixture-only probe (956-llei): a RETIRED test whose step fails loudly if run.
name: ${retired_name}
spec: ${spec_slug}
phase: retired
size: instant
severity: low
description: >
  Fixture probe: retired phase; executing it is the defect.
critical_path:
  - step: "retired step must not execute unless asked for"
    command: "echo RETIRED-PROBE-EXECUTED; exit 1"
    timeout_ms: 5000
    expected_behavior: "never-matches"
EOF

pass=0; fail=0
check() { if [ "$1" = ok ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$2"; else fail=$((fail + 1)); printf 'FAIL %s\n' "$2"; fi; }

# Arm 1: default phase filter ("all") — retired is skipped with its reason.
out="$(cd "$tmp" && TILLANDSIAS_PLAN_BIN="$PLAN_BIN" bash "$tmp/scripts/run-litmus-test.sh" "$spec_slug" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && grep -q 'Phase retired: runs only under --phase retired' <<<"$out" && ! grep -q 'RETIRED-PROBE-EXECUTED' <<<"$out"; then
    check ok "default filter: retired probe SKIPPED with the retired reason, suite passes (rc=$rc)"
else
    check FAIL "default filter: retired probe skipped (rc=$rc)"; grep -E 'SKIP|FAIL|RETIRED|Status' <<<"$out" | head -5 | sed 's/^/     /'
fi
# The live probe must have actually run — a suite that skipped everything
# would also pass arm 1 (bound-and-still-unrunnable).
if grep -qE 'live step passes.*\[OK\]|PASS.*retired-phase-live' <<<"$out"; then
    check ok "default filter: live probe executed"
else
    check FAIL "default filter: live probe executed"; grep -E 'live' <<<"$out" | head -3 | sed 's/^/     /'
fi

# Arm 2: --phase retired — the retired probe EXECUTES (and fails, loudly).
out="$(cd "$tmp" && TILLANDSIAS_PLAN_BIN="$PLAN_BIN" bash "$tmp/scripts/run-litmus-test.sh" "$spec_slug" --phase retired 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'RETIRED-PROBE-EXECUTED' <<<"$out"; then
    check ok "--phase retired: retired probe executed (rc=$rc)"
else
    check FAIL "--phase retired: retired probe executed (rc=$rc)"; grep -E 'SKIP|FAIL|RETIRED|Status' <<<"$out" | head -5 | sed 's/^/     /'
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then echo "PASS: litmus retired phase runs only when asked for ${pass}/${total} (956-llei)"; exit 0; fi
echo "FAIL: litmus retired phase ${fail}/${total} red (956-llei)"; exit 1
