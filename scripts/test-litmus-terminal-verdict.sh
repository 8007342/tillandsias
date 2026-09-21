#!/usr/bin/env bash
# @trace order:1309-fhxb
#
# A named skip and a declared advisory are TERMINAL NON-FAILURE verdicts. The
# load-bearing arm is not that they stop failing — it is that widening what
# counts as a non-failure did NOT widen what counts as a pass. A fabricated
# `skip:` after a genuine failure must stay RED, or this grammar becomes a way
# to erase any red by printing six characters.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 1
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  [OK]   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }

# Exercise the recognizer directly: it is the whole decision.
# shellcheck disable=SC1090
eval "$(awk '/^step_terminal_verdict\(\) \{/,/^\}/' scripts/run-litmus-test.sh)"
if ! declare -f step_terminal_verdict >/dev/null; then
    echo "FAIL: could not load step_terminal_verdict from the runner"; exit 1
fi

_v() { step_terminal_verdict "$1"; }

# ── the two measured instances ──────────────────────────────────────────────
[ "$(_v 'skip:no-cargo')" = skip ] \
  && ok "a named skip is a skip (test-spawn-failure-names-program's own output)" \
  || bad "a named skip was not recognised"
[ "$(_v 'advisory:bash-hazards:pgrep-f-literal:pipelines=4:files=3')" = advisory ] \
  && ok "a declared advisory is an advisory (check-bash-composition-hazards' own output)" \
  || bad "a declared advisory was not recognised"

# ── THE LOAD-BEARING CONTROL: fabrication must not work ─────────────────────
for failure in 'violation:something-real' 'refused:preflight:x' 'blocked:plan-ledger-incomplete' 'FAIL: the assertion was false'; do
    out="$(printf '%s\nskip:not-my-fault\n' "$failure")"
    if [ -z "$(_v "$out")" ]; then
        ok "a fabricated skip AFTER '${failure%%:*}:' does not rescue the step"
    else
        bad "a skip printed after '${failure%%:*}:' erased a real failure"
    fi
done

# ── the line must be the step's OWN verdict, not a mention ──────────────────
[ -z "$(_v "$(printf 'skip:mentioned-in-passing\nok:the-real-verdict\n')")" ] \
  && ok "a skip that is not the last line is not a verdict" \
  || bad "a skip mentioned mid-output was taken as the verdict"

# A script DESCRIBING the grammar must not be read as emitting it.
[ -z "$(_v "$(printf 'the script prints violation: when it refuses\nok:done\n')")" ] \
  && ok "an indented/inline mention of a failure word is not a failure verdict" \
  || bad "a failure word inside prose was read as a verdict"

# ── NEGATIVE CONTROL: an ordinary pass is untouched ─────────────────────────
[ -z "$(_v 'ok:everything-fine')" ] && ok "NEGATIVE CONTROL: an ordinary ok: output is not a skip or advisory" \
  || bad "an ok: output was diverted out of the pass path"
[ -z "$(_v '')" ] && ok "NEGATIVE CONTROL: empty output is not a terminal verdict" \
  || bad "empty output was read as a verdict"

# ── the assert_exit override is wired in the runner ─────────────────────────
if grep -q 'step_assert_exit" && "$exit_code" != "$step_assert_exit"' scripts/run-litmus-test.sh; then
    ok "a step declaring assert_exit that the status contradicts still FAILS, whatever it printed"
else
    bad "the assert_exit override is missing — a skip could overrule a false assertion"
fi

# ── the summary ADDS lines rather than reshaping them ───────────────────────
if grep -q "Pass Rate%b: %d%% (%d/%d executed)" scripts/run-litmus-test.sh; then
    ok "the existing Pass Rate line keeps its exact format (seven parsers read this surface)"
else
    bad "the Pass Rate line was reshaped — test-litmus-missing-bound-test-reds.sh asserts it literally"
fi

# ── THE ALL-SKIP TEST: a question not asked is not a green ──────────────────
# The case that forced test-level derivation. A test whose every executed step is
# a named skip counts PASSED under a step-only rule, and that is 1273-4mak's
# vacuous green one level up — the exact shape 1049-s35z's comment preserves:
# `Total: 3 (executed: 1, skipped: 2) / Pass Rate: 100% (1/1 executed) / PASS`
# while two born-red tests sat unobserved.
# NOTE: this arm inspects the DERIVATION in the runner rather than building a
# scratch litmus to run. An earlier draft wrote one into a temp dir and never
# used it, and check-litmus-pin-claims read the literal name in that heredoc as
# this fixture CLAIMING a litmus test no corpus file declares:
#   REFUSED: scripts/test-litmus-terminal-verdict.sh claims litmus:<name>
#            — no litmus test declares that name.
# A fixture that MENTIONS a litmus name is asserting that name exists, and dead
# code is not inert when a gate reads the file as text. The first attempt to
# document this wrote the offending token twice IN THE EXPLANATION and the
# checker refused it again, 2 occurrences instead of 1 — so this note describes
# the shape and never spells a name that no corpus file declares.
if grep -q '_t_pass" -eq 0 && "$_t_skip" -gt 0' scripts/run-litmus-test.sh; then
    ok "an all-skip test is SKIPPED, not a vacuous PASS (the derivation is wired)"
else
    bad "no all-skip rule — a test that asked no question would count as passed"
fi
# PIN THE PROPERTY, NOT THE SENTENCE. An earlier arm in this fixture asserted the
# roster read a function deleted hours before, and stayed green for nine runs
# because nothing changed the thing it named. So this asks whether BOTH labels
# the line prints are DEFINED on it, not whether a particular wording survives.
_tv="$(grep -A5 'Test Verdicts' scripts/run-litmus-test.sh | tr '\n' ' ')"
_missing=""
case "$_tv" in *"skipped ="*|*"skipped="*) ;; *) _missing="$_missing skipped" ;; esac
case "$_tv" in *"not-run ="*|*"not-run="*) ;; *) _missing="$_missing not-run" ;; esac
case "$_tv" in *"outside the rate"*) ;; *) _missing="$_missing denominator-rule" ;; esac
if [ -z "$_missing" ]; then
    ok "both labels and the denominator rule are stated on the Test Verdicts line"
else
    bad "the Test Verdicts line leaves these to be re-derived:$_missing"
fi
# The two populations must be COUNTED separately, not merely labelled separately.
if grep -q 'TESTS_SKIPPED:-0} - ${TESTS_VERDICT_SKIPPED:-0}' scripts/run-litmus-test.sh; then
    ok "not-run is TESTS_SKIPPED minus the verdict skips — the two labels count different populations"
else
    bad "skipped and not-run may be counting the same population under two names"
fi
# A test with SOME passing and SOME skipped steps is PASSED, not SKIPPED.
if grep -q '_t_pass" -eq 0 &&' scripts/run-litmus-test.sh; then
    ok "a test with some passing and some skipped steps stays PASSED (the rule keys on NO passing step)"
else
    bad "a single skipped step could demote a test that proved something"
fi

printf 'litmus-terminal-verdict %d/%d\n' "$pass" "$((pass+fail))"
[ "$fail" -eq 0 ] || exit 1
echo "ok:litmus-terminal-verdict:$pass/$pass"
