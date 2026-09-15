#!/usr/bin/env bash
# @trace order:1204-3s2s, order:1096-p3tn, spec:observability-metrics
#
# test-gate-step-metrics-isolation.sh — a gate step must not write into the
# host's shared metrics path.
#
# THE CHAIN THIS DEFENDS, measured end to end on lenovinha 2026-09-15 and
# reproduced from a clean state before the fix:
#   1. a fixture runs the litmus runner from a scratch dir that is NOT a git
#      checkout, so metrics_default_log correctly falls back to /tmp;
#   2. that fallback shares PRODUCTION'S BASENAME, so the records land in
#      /tmp/tillandsias-timing.jsonl carrying the host's REAL name;
#   3. cycle-metrics.sh sees two timing logs and refuses — correctly, 1096-p3tn:
#      a runs= from either half is a partition presenting as a total;
#   4. the refusal emits nothing, so every arm driving it observes zeros;
#   5. pre-build fails, ci-full never reaches post-build, and
#      check-release-tier-freshness.sh answers never:release-tier from then on.
# One missing env export in one fixture makes the entire release tier
# unmeasurable on the host that runs it. The fixture passed 7/7 while doing it.
#
# WHY THE GUARD IS BEHAVIOURAL AND NOT A GREP FOR THE EXPORT. 1096-p3tn fixed
# this BY HAND in eleven fixtures and wrote the convention in their comments;
# nothing enforced it, and the next fixture reintroduced it the same day with no
# way to know the convention existed. A static "every fixture must export
# TILLANDSIAS_TIMING_LOG" would be the ritual line 1204-3s2s's own negative
# control forbids — a fixture that produces NO timing output should not have to
# declare one. Watching the path distinguishes them, costs nothing (the steps
# already run), and catches writers no name-based scan can see.
#
# ARM 3 IS THE LOAD-BEARING ONE. Without a negative control, arm 2 passes
# against a world where nothing writes timing records at all, and this fixture
# would be asserting the absence of a thing that cannot happen.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3

SHARED=/tmp/tillandsias-timing.jsonl
SUBJECT="scripts/test-litmus-budget-tally.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

[ -f "$ROOT/$SUBJECT" ] || { echo "skip:step-metrics-isolation:$SUBJECT absent"; exit 3; }

# NEVER DESTROY A HOST'S RECORDS. If the shared path already exists this host is
# mid-split; preserve it, restore it, and say so rather than deleting evidence.
PRESERVED=""
if [ -f "$SHARED" ]; then
    PRESERVED="$(mktemp)"
    cp "$SHARED" "$PRESERVED"
    echo "note: $SHARED already exists ($(wc -l < "$SHARED") records) — preserved and restored at exit"
fi
restore() {
    if [ -n "$PRESERVED" ]; then cp "$PRESERVED" "$SHARED"; rm -f "$PRESERVED";
    else rm -f "$SHARED"; fi
}
trap restore EXIT

echo "arm 1 — the gate's step loop carries the isolation check"
if grep -q '1204-3s2s' "$ROOT/build.sh" \
   && grep -q '_metrics_shared_before' "$ROOT/build.sh" \
   && grep -q '_metrics_shared_after' "$ROOT/build.sh"; then
    ok "build.sh compares the shared path across each step and refuses on growth"
else
    bad "build.sh no longer guards the shared metrics path around gate steps"
fi

echo "arm 2 — the subject fixture does not reach the host's timing log"
rm -f "$SHARED"
bash "$ROOT/$SUBJECT" >/dev/null 2>&1
if [ -f "$SHARED" ]; then
    bad "$SUBJECT wrote $(wc -l < "$SHARED") record(s) into $SHARED — the split is back"
else
    ok "$SUBJECT ran without creating $SHARED"
fi

echo "arm 3 — NEGATIVE CONTROL: the runner in a non-checkout scratch dir DOES split"
# Proves arm 2 discriminates. Tests the MECHANISM rather than a doctored copy of
# the fixture: the first draft stripped the env assignments out of a copy placed
# in a temp dir, and that copy resolves its own ROOT from $0 — so it landed on
# /tmp, copied no scripts/, never reached the runner, and wrote nothing. It
# "passed" the absence check for a reason having nothing to do with the subject,
# which is the vacuous-arm shape this whole row is about.
rm -f "$SHARED"
_nc="$(mktemp -d)"
mkdir -p "$_nc/scripts" "$_nc/openspec/litmus-tests"
cp -r "$ROOT/scripts/." "$_nc/scripts/" 2>/dev/null
_l="litmus"; _s="metrics-isolation-probe"; _n="${_l}:${_s}"
cat > "$_nc/openspec/litmus-bindings.yaml" <<BIND
version: '1.0'
description: throwaway registry built at runtime
specs:
- spec_id: ${_s}
  status: active
  litmus_tests:
  - ${_n}
  coverage_ratio: 100
  last_verified: '2026-01-01'
BIND
cat > "$_nc/openspec/litmus-tests/litmus-${_s}.yaml" <<SPEC
name: ${_n}
spec: ${_s}
phase: pre-build
description: >
  A throwaway probe built by test-gate-step-metrics-isolation.sh.
severity: high
size: instant
critical_path:
  - step: "the probe step"
    command: "echo ok-probe"
    timeout_ms: 30000
    expected_behavior: "ok-probe"
SPEC
( cd "$_nc" && bash "$_nc/scripts/run-litmus-test.sh" "$_s" --phase pre-build --size all >/dev/null 2>&1 )
if [ -f "$SHARED" ]; then
    ok "an unnamed run wrote $(wc -l < "$SHARED") record(s) to $SHARED — arm 2 is a real assertion"
else
    bad "the runner did not split the log even unnamed; arm 2 proves nothing and this fixture is vacuous"
fi
rm -rf "$_nc"
rm -f "$SHARED"

echo "arm 4 — CONTROL: the guard keys on GROWTH, not on the file existing"
# A host legitimately mid-split (a forge, an out-of-repo run) must not make
# every subsequent step fail. The gate compares before/after, so a pre-existing
# file that no step adds to is not an offence.
if grep -q '\-gt "\${_metrics_shared_before:-0}"' "$ROOT/build.sh"; then
    ok "the comparison is before-vs-after, so a pre-existing file alone does not refuse"
else
    bad "the guard does not compare against a baseline — a pre-existing file would fail every step"
fi

echo
echo "gate-step metrics isolation: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    echo "violation:step-metrics-isolation:$fail"
    exit 1
fi
echo "ok:step-metrics-isolation:$pass"
exit 0
