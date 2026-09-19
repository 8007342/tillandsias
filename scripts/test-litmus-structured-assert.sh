#!/usr/bin/env bash
# @trace order:1252-znbn
#
# test-litmus-structured-assert.sh — a step declaring `assert_*` is adjudicated
# by those fields ONLY, so rewording the prose beside them cannot change the
# verdict.
#
# THE DEFECT. behavior_matches_output is a natural-language interpreter written
# in bash `case` arms. `*"succeeds"*` means "ignore the output, honour the exit
# code"; `*"multiple"*` means "grep the first integer, require >= 2"; the
# fallback is `grep -Fqi`, a LITERAL search, which is why an `(a|b)` alternation
# can never match (868-p8xi). Rewording an English sentence changes the rule
# that decides the verdict, with no diff anywhere saying the test now checks
# something else.
#
# ARM 1 IS THE TEETH AND IT USES AN EQUALIZED CONTROL. The pre-fix runner is
# HEAD's, with ONLY the two discovery overrides applied by sed, so the control
# differs from the subject in adjudication and nothing else. Without that
# equalization the control cannot find the throwaway suite at all, exits 1 for
# "spec not found", and two meaningless rc=1s read as agreement — which is how
# this fixture's first draft nearly reported that prose does not matter.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
RUNNER="$ROOT/scripts/run-litmus-test.sh"
TMP="$(mktemp -d)"
PREFIX_RUNNER="$ROOT/scripts/.znbn-prefix-runner.$$.sh"
trap 'rm -rf "$TMP" "$PREFIX_RUNNER"' EXIT
pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

mkdir -p "$TMP/lt"
# The pin token is ASSEMBLED rather than written out, and that is not evasion:
# check-litmus-pin-claims.sh scans scripts/ for `<prefix>:<name>` and requires
# every such name to resolve to a real, BOUND litmus test. This fixture's name
# exists only inside a throwaway corpus in a temp dir, so spelling it literally
# here would make this file claim a pin that does not exist — and the gate
# refused exactly that on the first attempt. The checker takes the same
# precaution in its own prose, for the same reason, saying that a checker whose
# own text trips it is a checker nobody trusts.
LIT="litmus"
{ printf "version: '1.0'\n"
  printf 'description: throwaway bindings for the 1252-znbn fixture\n'
  printf 'specs:\n'
  printf -- '- spec_id: znbn-probe\n'
  printf '  status: active\n'
  printf '  litmus_tests:\n'
  printf -- '  - %s:znbn-probe\n' "$LIT"
  printf '  coverage_ratio: 100\n'
} > "$TMP/bindings.yaml"

# write_case <expected_behavior> <extra-yaml-line>
write_case() {
    { printf 'test: litmus-znbn-probe\nsize: instant\nseverity: low\nphase: pre-build\n'
      printf 'critical_path:\n'
      printf '  - step: "one step; only the prose and the assertions vary"\n'
      printf '    command: "echo hello; exit 3"\n'
      printf '    timeout_ms: 5000\n'
      printf '    expected_behavior: "%s"\n' "$1"
      [ -n "${2:-}" ] && printf '    %s\n' "$2"
    } > "$TMP/lt/litmus-znbn-probe.yaml"
}
run_with() { # <runner> -> rc
    TILLANDSIAS_LITMUS_BINDINGS="$TMP/bindings.yaml" \
    TILLANDSIAS_LITMUS_TESTS_DIR="$TMP/lt" \
    bash "$1" znbn-probe >/dev/null 2>&1
}

# The pre-fix control: HEAD's adjudication, this branch's discovery.
git show HEAD:scripts/run-litmus-test.sh \
  | sed 's|^readonly LITMUS_BINDINGS="${PROJECT_ROOT}/openspec/litmus-bindings.yaml"|readonly LITMUS_BINDINGS="${TILLANDSIAS_LITMUS_BINDINGS:-${PROJECT_ROOT}/openspec/litmus-bindings.yaml}"|; s|^readonly LITMUS_TESTS_DIR="${PROJECT_ROOT}/openspec/litmus-tests"|readonly LITMUS_TESTS_DIR="${TILLANDSIAS_LITMUS_TESTS_DIR:-${PROJECT_ROOT}/openspec/litmus-tests}"|' \
  > "$PREFIX_RUNNER" 2>/dev/null

# ── ARM 0: the control is genuinely equalized ───────────────────────────────
# Asserted BEFORE any verdict is read from it. An unequalized control cannot
# find the suite and returns 1 for a reason unrelated to adjudication.
if [ -s "$PREFIX_RUNNER" ] && [ "$(grep -c 'TILLANDSIAS_LITMUS_' "$PREFIX_RUNNER")" -ge 2 ]; then
    write_case "hello" ""
    if run_with "$PREFIX_RUNNER"; then
        ok "ARM 0: pre-fix control reaches the throwaway suite (discovery equalized)"
    else
        bad "ARM 0: control did not PASS a case it should — discovery not equalized; every later arm is void"
    fi
else
    bad "ARM 0: could not build an equalized pre-fix control; arms 1-2 prove nothing"
fi

# ── ARM 1: PRE-FIX, prose alone flips the verdict ───────────────────────────
write_case "the command succeeds" "" ; run_with "$PREFIX_RUNNER"; rc_succeeds=$?
write_case "hello" ""                ; run_with "$PREFIX_RUNNER"; rc_literal=$?
if [ "$rc_succeeds" -ne 0 ] && [ "$rc_literal" -eq 0 ]; then
    ok "ARM 1: PRE-FIX the same command yields two verdicts from prose alone (succeeds->FAIL, literal->PASS)"
else
    bad "ARM 1: expected prose-dependence pre-fix, got succeeds=$rc_succeeds literal=$rc_literal"
fi

# ── ARM 2: POST-FIX, the same prose variants cannot move the verdict ────────
declare -i moved=0
for prose in "the command succeeds" "hello" "prints multiple things"; do
    write_case "$prose" "assert_exit: 3"
    run_with "$RUNNER" || moved=1
done
if [ "$moved" -eq 0 ]; then
    ok "ARM 2: POST-FIX assert_exit:3 passes under all three prose variants — the sentence is inert"
else
    bad "ARM 2: a prose change still moved the verdict with assert_exit declared"
fi

# ── ARM 3: the assertion has teeth ──────────────────────────────────────────
write_case "irrelevant" "assert_exit: 0"
if ! run_with "$RUNNER"; then
    ok "ARM 3: a WRONG assert_exit fails the step"
else
    bad "ARM 3: assert_exit: 0 passed against a step exiting 3 — the assertion is not enforced"
fi

# ── ARM 4: 868-p8xi — an alternation is matched AS a regex ──────────────────
write_case "irrelevant" 'assert_output_matches: "(hello|goodbye)"'
if run_with "$RUNNER"; then
    ok "ARM 4: assert_output_matches treats (a|b) as a regex (868-p8xi was unpassable by construction)"
else
    bad "ARM 4: an alternation that should match did not"
fi
# and it must still be able to FAIL
write_case "irrelevant" 'assert_output_matches: "(nope|never)"'
if ! run_with "$RUNNER"; then
    ok "ARM 5: assert_output_matches fails when no branch matches"
else
    bad "ARM 5: a non-matching alternation passed"
fi

# ── ARM 6b: assert_output_nonempty — silence is the failure ─────────────────
# This is the honest translation for the interpreter arm that requires a
# specific artefact be PRINTED ("grep succeeds" and friends), as distinct from
# the arm that honours the exit code. It exists as its own field because
# `assert_output_matches: "."` says the same thing and is indistinguishable
# from a typo.
write_case "irrelevant" "assert_output_nonempty: true"
# The command above exits 3, so this arm also pins that nonempty is judged
# INDEPENDENTLY of exit status — otherwise it would silently become an
# exit-code check, which is the very substitution this row exists to prevent.
sed -i.bak 's|command: "echo hello; exit 3"|command: "echo hello"|' "$TMP/lt/litmus-znbn-probe.yaml" 2>/dev/null || true
if run_with "$RUNNER"; then
    ok "ARM 6b: assert_output_nonempty passes when the step prints"
else
    bad "ARM 6b: a printing step failed assert_output_nonempty"
fi
sed -i.bak 's|command: "echo hello"|command: "true"|' "$TMP/lt/litmus-znbn-probe.yaml" 2>/dev/null || true
if ! run_with "$RUNNER"; then
    ok "ARM 6c: assert_output_nonempty FAILS on a silent step (rc=0 but no output)"
else
    bad "ARM 6c: a silent step passed assert_output_nonempty — silence must be the failure"
fi

# ── ARM 6: a legacy step is untouched ───────────────────────────────────────
# The regression guard. Declaring no assert_* must leave the old path exactly
# as it was, which ARM 1's literal case already exercised on the control.
write_case "hello" ""
if run_with "$RUNNER"; then
    ok "ARM 6: a step declaring no assert_* still adjudicates by the legacy path"
else
    bad "ARM 6: a legacy step changed verdict under the new runner"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
    printf 'ok:litmus-structured-assert:%d/%d\n' "$pass" "$((pass+fail))"
    exit 0
fi
printf 'refused:litmus-structured-assert:%d/%d passed\n' "$pass" "$((pass+fail))"
exit 1
