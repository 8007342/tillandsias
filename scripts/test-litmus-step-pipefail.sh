#!/usr/bin/env bash
# @trace order:1293-wka4, spec:spec-traceability
#
# THE DEFECT. run-litmus-test.sh runs under `set -uo pipefail`, but that is a
# property of THAT shell. Each step is spawned with a fresh `bash -c`, which
# does not inherit it — so `producer | head` returned 0 when the producer exited
# non-zero, and a step declaring `assert_exit: 0` adjudicated HEAD's status
# rather than the producer's. The row's reproduction returned 0:
#
#   bash -c 'sh -c "echo out; exit 7" 2>&1 | head -20'; echo $?
#
# WHY THE FIX IS SHAPE-GATED AND NOT A BLANKET, which is the whole design and
# the reason this fixture has arm 4. Measured on this corpus: 25 steps declaring
# assert_exit have a TOP-LEVEL pipe, but only 3 end in a status-swallowing
# consumer. The other 22 end in `grep -q`, where grep IS the adjudicator — and
# several are NEGATED, where pipefail inverts the verdict outright: a failing
# producer today makes the pipeline 0 and the negation 1 (fail); under pipefail
# it becomes non-zero and the negation 0 (pass). A blanket would silently flip
# those 22 while fixing 3.
#
# WHAT THIS CANNOT REACH, stated because it is a real hole and not an oversight:
# a step whose command is `bash -lc '... | tee ...'` runs its pipeline in a
# GRANDCHILD, and the prelude set in the spawned shell does not reach it —
# measured, rc=0 — which is this row's own defect one level down. SHELLOPTS is
# the usual propagation route and is READONLY here, so that door is closed.
# Arm 5 pins the limitation so a reader does not assume coverage this does not
# have. Two of the three corpus steps in the hazard class are that shape, and
# both are on unbound-grandfathered.txt — they have never run.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"

TMP="$(mktemp -d)"
PREFIX_RUNNER="$ROOT/scripts/.wka4-prefix-runner.$$.sh"
trap 'rm -rf "$TMP" "$PREFIX_RUNNER"' EXIT

LIT="litmus"
pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

mkdir -p "$TMP/tests"
cat > "$TMP/bindings.yaml" <<YAML
version: '1.0'
description: fixture for 1293-wka4
specs:
- spec_id: spec-traceability
  status: active
  ${LIT}_tests:
  - ${LIT}:wka4-probe
  coverage_ratio: 100
  last_verified: '2026-09-20'
YAML

# write_probe <command> ; runs it as a real litmus step, echoes PASS or FAIL
write_probe() {
    cat > "$TMP/tests/${LIT}-wka4-probe.yaml" <<YAML
name: ${LIT}:wka4-probe
spec: spec-traceability
phase: pre-build
severity: high
size: instant
description: >
  probe for 1293-wka4
critical_path:
  - step: "probe"
    command: "$1"
    timeout_ms: 5000
    expected_behavior: "the producer's status must reach the verdict"
    assert_exit: 0
YAML
}
run_probe() {  # <runner>
    TILLANDSIAS_LITMUS_BINDINGS="$TMP/bindings.yaml" \
    TILLANDSIAS_LITMUS_TESTS_DIR="$TMP/tests" \
        timeout 120 "$1" spec-traceability --phase pre-build --size instant --compact 2>&1 \
        | sed 's/\x1b\[[0-9;]*m//g' | grep -oE '^Status: \[(PASS|FAIL)\]' | head -1
}

# ---------------------------------------------------------------- ARM 1
# THE ROW'S EXACT REPRODUCTION, run as the row wrote it. Pre-fix it returned 0.
repro_rc=0
LITMUS_STDLIB="$ROOT/scripts/${LIT}-stdlib.sh" \
    bash -c 'set -o pipefail; source "$LITMUS_STDLIB"; sh -c "echo out; exit 7" 2>&1 | head -20' \
    >/dev/null 2>&1 || repro_rc=$?
if [ "$repro_rc" -eq 7 ]; then
    ok "ARM 1: the reproduction returns 7 when the spawned shell carries pipefail (pre-fix: 0)"
else
    bad "ARM 1: the reproduction returned $repro_rc, expected 7"
fi

# ---------------------------------------------------------------- ARM 2
# THROUGH THE REAL RUNNER: a producer that fails into a filter now REDS.
write_probe 'sh -c \"echo out; exit 7\" 2>&1 | head -20'
verdict="$(run_probe "$ROOT/scripts/run-${LIT}-test.sh")"
if [ "$verdict" = "Status: [FAIL]" ]; then
    ok "ARM 2: a step whose producer fails into head is RED (assert_exit no longer adjudicates the filter)"
else
    bad "ARM 2: expected FAIL, got '${verdict:-<none>}'"
fi

# ---------------------------------------------------------------- ARM 3
# PRE-FIX CONTROL. Neutralise the prelude in a COPY and require the false green
# to come back. Without this, arm 2 would stay green if the fix were deleted.
sed 's|^ *step_shell_prelude="set -o pipefail; "|                    step_shell_prelude=""|' \
    "$ROOT/scripts/run-${LIT}-test.sh" > "$PREFIX_RUNNER" 2>/dev/null
chmod +x "$PREFIX_RUNNER" 2>/dev/null
live_hits="$(grep -c 'step_shell_prelude="set -o pipefail; "' "$ROOT/scripts/run-${LIT}-test.sh")"
mut_hits="$(grep -c 'step_shell_prelude="set -o pipefail; "' "$PREFIX_RUNNER")"
if [ "$live_hits" -ge 1 ] && [ "$mut_hits" -eq 0 ]; then
    verdict="$(run_probe "$PREFIX_RUNNER")"
    if [ "$verdict" = "Status: [PASS]" ]; then
        ok "ARM 3: PRE-FIX the same step PASSES — the defect reproduces on demand"
    else
        bad "ARM 3: pre-fix copy did not reproduce the false green (got '${verdict:-<none>}')"
    fi
else
    bad "ARM 3: mutation did not apply (live=$live_hits mutant=$mut_hits) — refusing a verdict from an unmutated copy"
fi

# ---------------------------------------------------------------- ARM 4
# THE NEGATIVE CONTROLS THAT MAKE THE GATING WORTH IT.
write_probe 'sh -c \"echo out; exit 0\" 2>&1 | head -20'
verdict="$(run_probe "$ROOT/scripts/run-${LIT}-test.sh")"
if [ "$verdict" = "Status: [PASS]" ]; then
    ok "ARM 4a: a pipeline that genuinely succeeds still passes"
else
    bad "ARM 4a: a genuinely-succeeding pipeline now fails ('${verdict:-<none>}') — false green traded for false red"
fi

# The 22-step class: the pipeline ENDS in the assertion. A failing producer here
# must NOT change the verdict, or this fix breaks more than it repairs.
write_probe 'sh -c \"echo hit; exit 7\" 2>&1 | grep -q hit'
verdict="$(run_probe "$ROOT/scripts/run-${LIT}-test.sh")"
if [ "$verdict" = "Status: [PASS]" ]; then
    ok "ARM 4b: a grep-adjudicated step is UNCHANGED — the 22 steps a blanket would have inverted are untouched"
else
    bad "ARM 4b: a grep-adjudicated step changed verdict ('${verdict:-<none>}') — the gating is not holding and a blanket has been applied"
fi

# ---------------------------------------------------------------- ARM 5
# THE LIMITATION, PINNED. A grandchild shell still does not inherit the prelude.
# This arm asserts the HOLE so that closing it later is a visible change rather
# than an accident, and so nobody reads this fixture as proving more than it does.
gc_rc=0
bash -c 'set -o pipefail; bash -lc "sh -c \"exit 7\" | head -1"' >/dev/null 2>&1 || gc_rc=$?
if [ "$gc_rc" -eq 0 ]; then
    ok "ARM 5: KNOWN HOLE pinned — a bash -lc grandchild still does not inherit pipefail (rc=0); steps wrapping their pipeline that way are NOT covered"
else
    bad "ARM 5: the grandchild now returns $gc_rc — the hole closed, which is good news that must be recorded on 1293-wka4 and this arm updated rather than left asserting a limitation that no longer exists"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
    printf 'ok:%s-step-pipefail:%d/%d\n' "$LIT" "$pass" "$((pass + fail))"
    exit 0
fi
printf 'blocked:%s-step-pipefail:%d-failed-of-%d\n' "$LIT" "$fail" "$((pass + fail))"
exit 1
