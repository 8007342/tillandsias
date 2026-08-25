#!/usr/bin/env bash
# @trace spec:litmus-framework
# =============================================================================
# test-litmus-scalar-unescape.sh — fixtures for order 875-v7hv.
#
# THE DEFECT. `run-litmus-test.sh` parses a step's fields with bash regexes,
# which capture the RAW BYTES between a double-quoted YAML scalar's outer
# quotes. A YAML `\"` therefore arrives as backslash-quote and has to be
# unescaped by hand. That unescaping was applied to `command:` alone (added
# under plan/issues/litmus-runner-command-backslash-escaping-2026-07-06.md)
# and to none of `expected_behavior:`, `success_pattern:`, `failure_pattern:`.
#
# So a step whose command emits a double quote and whose expected_behavior
# declares that same text could never match itself. Measured on yoga
# 2026-08-25, on the first run of a newly-bound file:
#     expected=out.push((\"no_proxy\".to_string(), ...));
#     output=        out.push(("no_proxy".to_string(), ...));
# — a reported content mismatch between two strings that are identical.
#
# The dangerous direction is `failure_pattern`: one carrying `\"` silently
# never matches, so a real failure signal is missed and the step reports green.
# An assertion that cannot fire is worse than an absent one, which is why this
# fixture asserts the ROUTING as well as the function.
#
# Scenarios:
#   A. the helper's own semantics, including the ordering property (a raw
#      backslash-pair before a quote must keep that quote LITERAL, the way a
#      real YAML parser consumes escapes left to right);
#   B. NEGATIVE CONTROL — a version of the helper with the passes in the wrong
#      order is proven to produce a DIFFERENT answer, so scenario A is not
#      passing by accident;
#   C. ROUTING — every double-quoted step field goes through the helper, and
#      the PLAIN-scalar expected_behavior branch deliberately does not (an
#      unquoted YAML scalar has no escape sequences, so unescaping one would
#      corrupt it).
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/run-litmus-test.sh"
fail=0
ok()  { printf '  ok: %s\n' "$1"; }
bad() { printf '  FAIL: %s\n' "$1"; fail=1; }

[ -r "$RUNNER" ] || { printf 'blocked:runner-unreadable:%s\n' "$RUNNER"; exit 2; }

# Load the REAL function by name rather than reimplementing it, so this fixture
# cannot drift into testing a copy that no longer matches shipped behaviour.
fn_src="$(awk '/^yaml_unescape_dq\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$RUNNER")"
if [ -z "$fn_src" ]; then
    printf 'violation:helper-absent:yaml_unescape_dq not defined in run-litmus-test.sh\n'
    exit 1
fi
eval "$fn_src"

# ── A. semantics ────────────────────────────────────────────────────────────
check() {
    local label="$1" input="$2" want="$3" got
    got="$(yaml_unescape_dq "$input")"
    if [ "$got" = "$want" ]; then ok "$label"; else
        bad "$label: want [$want] got [$got]"
    fi
}
check 'an escaped quote becomes a quote'        'a\"b'      'a"b'
check 'an escaped backslash becomes one'        'a\\b'      'a\b'
check 'plain text is untouched'                 'abc def'   'abc def'
check 'the empty string is untouched'           ''          ''
check 'a real-world grep pattern survives'      'grep -F '"'"'x(\"k\".to_string())'"'"'' 'grep -F '"'"'x("k".to_string())'"'"''
# The ordering property, with an input that actually discriminates: a raw
# \\\\ followed by a quote. YAML consumes escapes left to right, so the
# pair is the escaped-backslash sequence and the quote that follows is a
# literal one -> a single backslash then a quote.
check 'ordering: an escaped backslash before a quote keeps the quote literal' 'x\\"y' 'x\"y'

# ── B. negative control for the ordering ────────────────────────────────────
# A wrong-order implementation must NOT agree with the shipped one, or
# scenario A's ordering case proves nothing.
wrong_order() { local s="$1"; s="${s//\\\\/\\}"; s="${s//\\\"/\"}"; printf '%s' "$s"; }
if [ "$(wrong_order 'x\\"y')" = "$(yaml_unescape_dq 'x\\"y')" ]; then
    bad 'NEGATIVE CONTROL: wrong-order unescape agrees with the shipped one — the ordering case is vacuous'
else
    ok 'NEGATIVE CONTROL: wrong-order unescape gives a different answer'
fi

# ── C. routing ──────────────────────────────────────────────────────────────
# Assert the ABSENCE of a raw capture for each double-quoted field, which stays
# true however the surrounding parser is rewritten (634-39ik). A field
# reintroduced as a bare ${BASH_REMATCH[1]} is exactly the regression.
for field in current_step_command current_step_success_pattern current_step_failure_pattern; do
    if grep -qE "^[[:space:]]*${field}=\"\\\$\(yaml_unescape_dq " "$RUNNER"; then
        ok "routing: $field is unescaped through the helper"
    else
        bad "routing: $field does not route through yaml_unescape_dq"
    fi
    if grep -qE "^[[:space:]]*${field}=\"\\\$\{BASH_REMATCH\[1\]\}\"[[:space:]]*$" "$RUNNER"; then
        bad "routing: $field still has a RAW capture assignment"
    fi
done

# expected_behavior has two branches and they must differ: the double-quoted
# one is unescaped, the plain-scalar one is not.
dq_n=$(grep -cE '^[[:space:]]*current_step_expected="\$\(yaml_unescape_dq ' "$RUNNER")
raw_n=$(grep -cE '^[[:space:]]*current_step_expected="\$\{BASH_REMATCH\[1\]\}"[[:space:]]*$' "$RUNNER")
[ "$dq_n" -eq 1 ] && ok 'routing: the double-quoted expected_behavior branch is unescaped' \
    || bad "routing: expected exactly 1 unescaped expected_behavior branch, found $dq_n"
[ "$raw_n" -eq 1 ] && ok 'routing: the PLAIN-scalar expected_behavior branch is left raw (correct: no escapes exist in one)' \
    || bad "routing: expected exactly 1 raw expected_behavior branch, found $raw_n"

if [ "$fail" -eq 0 ]; then
    echo 'ok:litmus-scalar-unescape'
else
    echo 'violation:litmus-scalar-unescape'
fi
exit "$fail"
