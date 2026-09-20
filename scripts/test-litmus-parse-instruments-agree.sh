#!/usr/bin/env bash
# @trace spec:litmus-framework
#
# test-litmus-parse-instruments-agree.sh — ORDER 1303-2d5g.
#
# WHAT THIS PINS. `run-litmus-test.sh --parse-only` used to answer `ok:` for a
# file that `tillandsias-plan validate-yaml` REFUSES, because the runner's step
# extraction is LINE-BASED and never loaded the document. It even reported a
# step count from an unparseable file. Order 1274-cbk7 had already added a note
# saying parse-only answers extractability and not validity; the note printed
# directly above the `ok:` line and did not help, because a reader acts on the
# VERDICT WORD. Two instruments disagreeing about one file — the looser one
# being the one authors reach for first — is how a broken litmus reaches a gate
# on one host and is refused on another.
#
# THREE ARMS, matching this row's closure:
#   1. a file that is NOT valid YAML is REFUSED by --parse-only: non-zero exit,
#      a verdict line that does NOT begin with `ok:`, and the same file and
#      line that `validate-yaml` names.
#   2. a VALID litmus file is accepted by BOTH instruments (the fix must not
#      turn the strict arm into a blanket refusal).
#   3. MUTATION: with the document load removed from --parse-only, arm 1 stops
#      holding — proving the load is what earns arm 1 rather than some
#      incidental property of the fixture.
#
# THE FIXTURE LIVES OUTSIDE openspec/litmus-tests ON PURPOSE. The strict gate
# globs that directory, so a deliberately-broken file placed there would red
# the real corpus gate. It is written to a temp dir at run time instead.
#
# Grammar (one line on stdout, nothing else):
#   ^(ok:litmus-parse-instruments-agree:[0-9]+/3|violation:litmus-parse-instruments-agree:[0-9]+/3|skip:no-runnable-reader)$
# Exit 0 on the ok and on the skip; 1 on a violation.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

RUNNER="$ROOT/scripts/run-litmus-test.sh"

. "$ROOT/scripts/plan-binary-probe.sh"
READER="$(resolve_plan_binary 2>/dev/null || true)"
if [ -z "$READER" ] || [ ! -x "$READER" ]; then
    # Same stand-aside, and the same wording, as
    # scripts/check-litmus-yaml-parses.sh: two instruments answering one
    # question must not differ on what "cannot answer" looks like.
    echo "skip:no-runnable-reader"
    exit 0
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/litmus-parse-agree.XXXXXX")"
MUTANT=""
cleanup() { rm -rf "$W"; [ -n "$MUTANT" ] && rm -f "$MUTANT"; }
trap cleanup EXIT

# 933-4gm8's recorded shape: a plain-scalar list item carrying ": " and
# continuing onto a second line, which YAML scans as a keyless mapping key.
cat > "$W/bad.yaml" <<'YAML'
name: litmus:fixture-not-yaml
spec: fixture-spec
phase: pre-build
description: >
  Deliberately unparseable. Used only by this fixture.
severity: low
size: instant

preconditions:
  - this item is the hazard: a plain scalar carrying a colon-space pair
    and continuing onto a second line

critical_path:
  - step: "a step that does nothing"
    command: "echo ok"
    expected_behavior: "ok"
    assert_exit: 0
    timeout_ms: 1000
YAML

cat > "$W/good.yaml" <<'YAML'
name: litmus:fixture-valid
spec: fixture-spec
phase: pre-build
description: >
  Valid YAML and extractable. Used only by this fixture.
severity: low
size: instant

critical_path:
  - step: "a step that does nothing"
    command: "echo ok"
    expected_behavior: "ok"
    assert_exit: 0
    timeout_ms: 1000
YAML

fail() { echo "FAIL: $*" >&2; }
passed=0

# --- Arm 0 (premise): the strict reader really does refuse bad.yaml ----------
# Without this the whole fixture could pass against a file that is actually
# fine, and prove nothing.
if strict_out="$("$READER" validate-yaml "$W/bad.yaml" 2>&1)"; then
    fail "premise broken: validate-yaml ACCEPTED the deliberately-bad fixture"
    echo "violation:litmus-parse-instruments-agree:0/3"
    exit 1
fi

# --- Arm 1: --parse-only refuses it, naming what the strict checker names ----
arm1_out="$(bash "$RUNNER" --parse-only "$W/bad.yaml" 2>&1)"; arm1_rc=$?
if [ "$arm1_rc" -ne 0 ] \
   && ! printf '%s\n' "$arm1_out" | grep -qE '^ok:' \
   && printf '%s\n' "$arm1_out" | grep -q 'bad.yaml'; then
    passed=$((passed + 1))
else
    fail "arm 1: --parse-only did not refuse a non-YAML file (rc=$arm1_rc)"
    printf '%s\n' "$arm1_out" | tail -3 >&2
fi

# --- Arm 2: both instruments accept a valid file -----------------------------
arm2_out="$(bash "$RUNNER" --parse-only "$W/good.yaml" 2>&1)"; arm2_rc=$?
"$READER" validate-yaml "$W/good.yaml" >/dev/null 2>&1; strict_rc=$?
if [ "$arm2_rc" -eq 0 ] && [ "$strict_rc" -eq 0 ] \
   && printf '%s\n' "$arm2_out" | grep -qE '^ok:litmus-parseable'; then
    passed=$((passed + 1))
else
    fail "arm 2: a valid file was not accepted by both (runner=$arm2_rc strict=$strict_rc)"
    printf '%s\n' "$arm2_out" | tail -3 >&2
fi

# --- Arm 3 (mutation): remove the load, arm 1 must stop holding --------------
# The mutant lives in scripts/ because PROJECT_ROOT is derived from
# ${BASH_SOURCE[0]}/.. — a copy anywhere else resolves a different repo root
# and would fail for the wrong reason.
#
# The mutation is SURGICAL rather than a range delete: it makes the load's
# guard unreachable while leaving every block balanced. A range delete of
# "comment through the next fi" terminates at the wrong `fi` and produces a
# file that does not parse, which reds arm 3 for a reason that has nothing to
# do with the defect (measured while writing this).
MUTANT="$ROOT/scripts/.run-litmus-test.mutant-1303.$$.sh"
sed 's|if ! parse_yaml_out="$("$parse_reader" validate-yaml "$parse_target" 2>&1)"; then|if false; then|' \
    "$RUNNER" > "$MUTANT"
if ! grep -q 'if false; then' "$MUTANT"; then
    fail "arm 3: the mutation did not apply; the load line has been reworded"
    echo "violation:litmus-parse-instruments-agree:$passed/3"
    rm -f "$MUTANT"
    exit 1
fi
if ! bash -n "$MUTANT" 2>/dev/null; then
    fail "arm 3: the mutant does not parse; the deletion range needs updating"
else
    mut_out="$(bash "$MUTANT" --parse-only "$W/bad.yaml" 2>&1)"; mut_rc=$?
    if [ "$mut_rc" -eq 0 ] && printf '%s\n' "$mut_out" | grep -qE '^ok:litmus-parseable'; then
        passed=$((passed + 1))
    else
        fail "arm 3: removing the load did NOT restore the old behaviour (rc=$mut_rc) -- arm 1 may be passing for an unrelated reason"
        printf '%s\n' "$mut_out" | tail -3 >&2
    fi
fi
rm -f "$MUTANT"; MUTANT=""

if [ "$passed" -eq 3 ]; then
    echo "ok:litmus-parse-instruments-agree:3/3"
    exit 0
fi
echo "violation:litmus-parse-instruments-agree:$passed/3"
exit 1
