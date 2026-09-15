#!/usr/bin/env bash
# freshness: added 2026-09-15 linux-yoga (order 1187-iij8)
# @trace order:1187-iij8, order:820-c8q8, order:956-llei
#
# test-litmus-budget-tally.sh — a step killed at its budget is COUNTED apart
# from a failed assertion, and still fails.
#
# ── REGIME ───────────────────────────────────────────────────────────────────
# HERMETIC. Each case builds a throwaway PROJECT_ROOT under mktemp -d holding a
# copy of scripts/ and a single hand-written litmus spec, and runs the copied
# runner there. The real openspec/litmus-tests/ is never read and the real
# tally is never touched. No absolute timestamp appears here; the budgets are
# tiny relative durations (a 1s budget against a 5s sleep), so the fixture
# asserts a property rather than a wall-clock fact.
#
# ── THE ASSERTION THAT MATTERS IS NOT THE LABEL ──────────────────────────────
# ORDER 820-c8q8 settled that a timed-out step STILL FAILS, and
# run-litmus-test.sh says so at its rc=124 site: "Reported, never used to
# change the verdict". So the danger in 1187-iij8 is not that the BUDGET count
# is wrong — it is that someone implements it as a fourth BUCKET and a timeout
# stops failing. That would turn a noisy count into a fail-open gate, strictly
# worse than the noise it replaced.
#
# A fixture that only checked for the new label would PASS a version where the
# label is applied AND the verdict flipped — the exact bug the constraint
# forbids (lenovinha's framing, from getting this shape wrong on 1196-5hva
# earlier the same night). So every budget case here asserts THREE things:
#   the run exits NON-ZERO, the spec is still reported [FAIL], and only then
#   that the BUDGET line names it.
# Drop any one of those and the fixture stops defending the constraint.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# THE PROBE'S NAME IS ASSEMBLED, NOT WRITTEN OUT, and that is not evasion.
# ORDER 721-77yu refuses any file containing a `litmus:<name>` token that no
# declared litmus test provides — "the claim reads as verification and supplies
# none" — and it refused this fixture on its first land. The refusal is CORRECT:
# a bare litmus name in a script is indistinguishable, to any matcher, from a
# pin claiming that test verifies something.
#
# But this fixture does not CLAIM that test; it MANUFACTURES it, inside a
# throwaway root, as the subject under test. The string has to exist in the
# generated spec and must not exist as a claim in the tree. Building it at
# runtime says exactly that, and is the same remedy 1118-zvai used when a
# repo-wide sweep refused its own fixture's test data.
_LIT="litmus"; _PROBE_SPEC="budget-probe"; _PROBE_NAME="${_LIT}:${_PROBE_SPEC}"

pass=0; fail=0
_ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
_bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

# Build a throwaway root with one spec whose single step behaves as asked.
# $1 = step command, $2 = timeout_ms
#
# THE COMMAND MUST CONTAIN NO DOUBLE QUOTES AND NO COLONS. It is interpolated
# into a double-quoted YAML scalar, so `echo "ok: probe"` rendered as
# `command: "echo "ok: probe""` — invalid YAML. The runner did not error on it;
# it SKIPPED the test and reported NO-TESTS-EXECUTED, which every absence-based
# arm below reads as success. Hence the quote-free probe vocabulary.
_mkroot() {
    d="$(mktemp -d)"
    mkdir -p "$d/scripts" "$d/openspec/litmus-tests"
    cp -r "$ROOT/scripts/." "$d/scripts/" 2>/dev/null
    # The runner refuses without a bindings registry, and that refusal is
    # indistinguishable from a budget kill to an absence-based assertion — the
    # first draft of this fixture reported 4 green arms over a run that never
    # executed a step. Execution is binding-driven, so the probe must be bound.
    cat > "$d/openspec/litmus-bindings.yaml" <<BIND
version: '1.0'
description: throwaway registry built at runtime
specs:
- spec_id: ${_PROBE_SPEC}
  status: active
  litmus_tests:
  - ${_PROBE_NAME}
  coverage_ratio: 100
  last_verified: '2026-01-01'
BIND
    cat > "$d/openspec/litmus-tests/litmus-${_PROBE_SPEC}.yaml" <<EOF
name: ${_PROBE_NAME}
spec: ${_PROBE_SPEC}
phase: pre-build
description: >
  A throwaway probe built by test-litmus-budget-tally.sh.
severity: high
size: instant
critical_path:
  - step: "the probe step"
    command: "$1"
    timeout_ms: $2
    expected_behavior: "ok-probe"
EOF
    printf '%s\n' "$d"
}

_run() {  # echoes rc on the first line, then the output
    # --size all: without it the probe is selected and then EXCLUDED by the
    # size filter, and the runner correctly reports NO-TESTS-EXECUTED (913-27ex,
    # "THIS RUN IS NOT EVIDENCE OF ANYTHING"). That guard caught this fixture.
    ( cd "$1" && bash "$1/scripts/run-litmus-test.sh" "$_PROBE_SPEC" --phase pre-build --size all >"$1/out.txt" 2>&1; echo "rc=$?" )
    cat "$1/out.txt"
}

# PREMISE, asserted before any case reads a verdict. Every absence-based arm
# below ("no BUDGET line") is satisfied by a run that executed nothing, so the
# suite must first prove the probe is reachable at all. Measured: without the
# bindings file above, the runner exits 3 on a missing registry and FOUR arms
# reported green over a run that never started a step.
_probe="$(_mkroot 'echo ok-probe' 30000)"
_pout="$(_run "$_probe")"
case "$(printf '%s' "$_pout" | sed 's/\x1b\[[0-9;]*m//g')" in
    # Deliberately NOT matching the spec NAME: the runner prints
    # "filter 'budget-probe' selected 1 test(s) and executed NONE" when the
    # size filter excludes it, and an earlier draft of this arm passed on that
    # very line. Only a printed STEP proves a step ran.
    *"[STEP 1/1]"*)
        _ok "0 PREMISE: the throwaway spec is discovered and its step executes" ;;
    *)
        _bad "0 PREMISE: the throwaway spec is discovered and its step executes" \
             "the runner never reached the step; every absence assertion below would be vacuous" ;;
esac
rm -rf "$_probe"

# ── 1-3. A BUDGET KILL: non-zero, still FAIL, and named ─────────────────────
d="$(_mkroot 'sleep 5; echo ok-probe' 1000)"
out="$(_run "$d")"
rc="$(printf '%s' "$out" | sed -n 's/^rc=\([0-9]*\)$/\1/p' | head -1)"
plain="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"

if [ "${rc:-0}" != "0" ]; then
    _ok "1 a budget kill still exits NON-ZERO (rc=$rc)"
else
    _bad "1 a budget kill still exits NON-ZERO" "rc=$rc — the verdict flipped; this is the fail-open gate 820-c8q8 forbids"
fi

case "$plain" in
    *"Status: [FAIL]"*) _ok "2 a budget kill still reports Status: [FAIL]" ;;
    *) _bad "2 a budget kill still reports Status: [FAIL]" "no FAIL status in the summary" ;;
esac

case "$plain" in
    *"BUDGET"*"killed at their budget"*) _ok "3 the BUDGET line names it as a subset of the FAILs" ;;
    *) _bad "3 the BUDGET line names it" "no BUDGET line in: $(printf '%s' "$plain" | tail -6 | tr '\n' '|')" ;;
esac
rm -rf "$d"

# ── 4-5. NEGATIVE CONTROL: a genuine assertion failure is NOT a budget kill ──
# The row's own second exit criterion. Without this the counter could simply
# count every failure and the distinction it exists to draw would be fictional.
d="$(_mkroot 'echo not-the-expected-output; exit 1' 30000)"
out="$(_run "$d")"; rc="$(printf '%s' "$out" | sed -n 's/^rc=\([0-9]*\)$/\1/p' | head -1)"
plain="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
if [ "${rc:-0}" != "0" ]; then
    _ok "4 a genuine assertion failure still fails"
else
    _bad "4 a genuine assertion failure still fails" "rc=$rc"
fi
case "$plain" in
    *"killed at their budget"*) _bad "5 a genuine failure is NOT counted as a budget kill" "the BUDGET line appeared for a fast assertion failure" ;;
    *) _ok "5 a genuine failure is NOT counted as a budget kill" ;;
esac
rm -rf "$d"

# ── 6. A PASSING RUN SAYS NOTHING ABOUT BUDGETS ─────────────────────────────
# A line that prints always is a line nobody reads.
d="$(_mkroot 'echo ok-probe' 30000)"
out="$(_run "$d")"; plain="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
case "$plain" in
    *"killed at their budget"*) _bad "6 a green run prints no BUDGET line" "it printed one" ;;
    *) _ok "6 a green run prints no BUDGET line" ;;
esac
rm -rf "$d"

printf '\n'
if [ "$fail" -eq 0 ]; then
    printf 'ok:litmus-budget-tally:%d\n' "$pass"
    exit 0
fi
printf 'fail:litmus-budget-tally: %d passed, %d failed\n' "$pass" "$fail"
exit 1
