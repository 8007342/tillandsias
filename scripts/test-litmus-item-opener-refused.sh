#!/usr/bin/env bash
# @trace order:1252-znbn
#
# test-litmus-item-opener-refused.sh — a critical_path item opened by any key
# other than `step:` must be a PARSE ERROR, not a silent backwards merge.
#
# THE DEFECT THIS PINS. run-litmus-test.sh opens a critical_path item only on
# `- step: "..."`. An item opened by another key — `- name:` was the case
# measured on macuahuitl 2026-09-18 — matches no branch, falls through the
# parser's elif chain, and its `command:`/`timeout_ms:`/`expected_behavior:`
# keys OVERWRITE the step already in progress. The item merges backwards, later
# keys win, and a two-item file yields ONE unlabelled step.
#
# WHY IT SURVIVED. Every observable said fine. The YAML is well-formed, so
# ./build.sh --check's metadata validator passes the file; the runner prints a
# step count that silently omits the merged item and exits 0. A step that was
# lost and a step that was never written produce identical output, which is why
# this needs a guard rather than a convention.
#
# ARM 3 IS THE ONE THAT MATTERS. It MUTATES the fix back out and proves the
# pre-fix behaviour returns — `1 step(s)`, exit 0, no diagnostic, on a file
# declaring two items. An arm that only asserts today's refusal cannot tell a
# working guard from a guard that never ran.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
RUNNER="$ROOT/scripts/run-litmus-test.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

# Two items, the second opened by the WRONG key.
cat > "$TMP/merged.yaml" <<'YAML'
test: litmus-probe-merged-item
size: instant
severity: low
phase: pre-build
critical_path:
  - step: "first item, correctly opened"
    command: "echo ok:first"
    timeout_ms: 5000
    expected_behavior: "ok:first"
  - name: "second item, opened by the WRONG key"
    command: "echo ok:second"
    timeout_ms: 5000
    expected_behavior: "ok:second"
YAML

# Two items, both correct. The regression guard.
cat > "$TMP/valid.yaml" <<'YAML'
test: litmus-probe-valid
size: instant
severity: low
phase: pre-build
critical_path:
  - step: "first item"
    command: "echo ok:first"
    timeout_ms: 5000
    expected_behavior: "ok:first"
  - step: "second item"
    command: "echo ok:second"
    timeout_ms: 5000
    expected_behavior: "ok:second"
YAML

# A step name that is not a double-quoted scalar falls through identically.
cat > "$TMP/unquoted.yaml" <<'YAML'
test: litmus-probe-unquoted
size: instant
severity: low
phase: pre-build
critical_path:
  - step: unquoted name here
    command: "echo hi"
    timeout_ms: 5000
YAML

# ── ARM 1: the wrong opener is REFUSED, and the refusal names the key ────────
out="$(bash "$RUNNER" --parse-only "$TMP/merged.yaml" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q 'PARSE ERROR' \
   && printf '%s' "$out" | grep -q "'- name:'"; then
    ok "ARM 1: '- name:' item refused, and the refusal names the offending key"
else
    bad "ARM 1: expected a PARSE ERROR naming '- name:', got rc=$rc: $out"
fi

# ── ARM 2: an unquoted step name is refused for the same reason ──────────────
out="$(bash "$RUNNER" --parse-only "$TMP/unquoted.yaml" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'double-quoted scalar'; then
    ok "ARM 2: unquoted step name refused, remedy named"
else
    bad "ARM 2: expected refusal naming the double-quoted scalar, got rc=$rc: $out"
fi

# ── ARM 3: MUTATION — remove the fix, require the silent merge to return ─────
# Neutering the collection is the smallest mutation that restores the old
# behaviour exactly: the opener line is still consumed, and the item's later
# keys still overwrite the step in progress, which IS the pre-fix path.
# The replacement keeps the branch syntactically valid (a `then` body needs a
# command; comments are not one), so the mutant differs from the subject ONLY
# in whether the malformed item is recorded. Delimiter is `/`: the line being
# matched contains `|`, which silently broke an earlier `sed 's|...|...|'` here
# and made this arm report that it could not mutate — correctly, and that
# refusal is why the arm is written to fail loudly instead of skipping.
sed 's/^\( *\)malformed_items+=.*/\1:/' "$RUNNER" > "$TMP/mutant.sh" 2>/dev/null \
  || cp "$RUNNER" "$TMP/mutant.sh"
if ! grep -q 'malformed_items+=' "$TMP/mutant.sh"; then
    out="$(bash "$TMP/mutant.sh" --parse-only "$TMP/merged.yaml" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q ':1 step(s)'; then
        ok "ARM 3: MUTANT reproduces the silent merge — two items in, '1 step(s)', exit 0, no diagnostic"
    else
        bad "ARM 3: mutant did not reproduce the pre-fix merge (rc=$rc): $out"
    fi
else
    bad "ARM 3: could not build the mutant — the anchor 'malformed_items+=' did not mutate, so this arm proved nothing"
fi

# ── ARM 4: a well-formed file still parses, with the RIGHT count ─────────────
# The count is the assertion, not exit 0: the defect this guards produces a
# green exit with a wrong count, so a rc-only check would pass on it.
out="$(bash "$RUNNER" --parse-only "$TMP/valid.yaml" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q ':2 step(s)'; then
    ok "ARM 4: valid two-item file still parses as exactly 2 steps"
else
    bad "ARM 4: expected ok with 2 step(s), got rc=$rc: $out"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
    printf 'ok:litmus-item-opener-refused:%d/%d\n' "$pass" "$((pass+fail))"
    exit 0
fi
printf 'refused:litmus-item-opener-refused:%d/%d passed\n' "$pass" "$((pass+fail))"
exit 1
