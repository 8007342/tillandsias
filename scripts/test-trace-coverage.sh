#!/usr/bin/env bash
# =============================================================================
# Unit tests for trace coverage threshold validation
# @trace gap:OBS-004, spec:spec-trace-coverage-threshold, spec:testing
# =============================================================================

set -euo pipefail


# ORDER 799-tb7q — resolve `jq` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has it.
# shellcheck source=scripts/lib/tool-dispatch.sh
# Resolve the lib by WALKING UP, not by a fixed depth (order 914-ahsy). The
# fixed form `dirname "${BASH_SOURCE[0]}"/lib/...` is correct only for a caller
# sitting directly in scripts/. From scripts/refusal-calibration/ it points at a
# lib that does not exist, the `|| true` swallows the miss, and the tool variable
# silently falls back to the bare name — a conversion that passes review, passes
# the suite, and changes nothing.
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
if command -v resolve_tool >/dev/null 2>&1; then
    # 1063-nraf: RESOLVED AS AN ARGV ARRAY, not a single word. resolve_tool can
    # return a multi-word dispatch prefix — tool-dispatch.sh emits
    # `toolbox run --container <c> <tool>` when the host lacks the tool but a
    # toolbox has it. Every use here quoted it as "$JQ", so that five-word
    # string became one command name and the fixture died "command not found".
    # It works on a host with jq on PATH, which is why it was invisible here and
    # would have red-lit a macOS host, where the base OS ships no jq at all.
    JQ="$(resolve_tool jq || printf 'jq')"
else
    JQ="jq"   # lib unavailable: preserve the previous behaviour exactly
fi
# Split the (possibly multi-word) dispatch into an argv array once. `read -a`
# is bash 3.2-safe, so this works on stock macOS /bin/bash.
read -r -a JQ_CMD <<< "$JQ"

# 1063-nraf: JQ-DEPENDENT ARMS SKIP THEMSELVES WHEN jq IS ABSENT, and say so.
# Stock macOS ships no jq, so without this the fixture reports seven failures
# on a Mac for a reason that has nothing to do with trace coverage. A red for a
# missing tool is the intermittent-red shape that gets a check switched off.
#
# NOT A SILENT PASS. The skip prints a greppable token, and a host that only
# ever prints it is not being covered — that is a finding to file rather than a
# clean run, the same rule the 1036-e5w9 memo arm carries.
JQ_AVAILABLE=0
if printf '{}' | "${JQ_CMD[@]}" -e . >/dev/null 2>&1; then
    JQ_AVAILABLE=1
fi
_skip_jq() { echo "skip:test-trace-coverage:no-jq $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 1063-nraf: `passed` was NEVER INITIALISED and both counters used `((var++))`.
# Under this file's own `set -euo pipefail` that is two bugs in one line:
#   * set -u kills the first _pass on the unset `passed`;
#   * `((passed++))` POST-increments, so from 0 the arithmetic result is 0 and
#     the compound returns exit 1, which set -e treats as failure.
# The fixture therefore died on its FIRST passing assertion — which is why it
# exits non-zero while its last line reads like a pass ("✓ Rejects negative
# threshold"). It fails identically on macOS bash 3.2 and MSYS, so this was
# never a portability escape hatch. Assignment form returns 0 unconditionally.
passed=0
failed=0

_pass() { echo "✓ $*"; passed=$((passed + 1)); }
_fail() { echo "✗ $*"; failed=$((failed + 1)); }

echo "=== Trace Coverage Threshold Tests ==="
echo ""

# Test 1: Invalid threshold (negative)
echo "Test 1: Reject negative threshold"
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold -1 >/dev/null 2>&1; then
    _fail "Should reject negative threshold"
else
    _pass "Rejects negative threshold"
fi

# Test 2: Invalid threshold (>100)
echo "Test 2: Reject threshold > 100"
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 101 >/dev/null 2>&1; then
    _fail "Should reject threshold > 100"
else
    _pass "Rejects threshold > 100"
fi

# Test 3: Invalid threshold (non-numeric)
echo "Test 3: Reject non-numeric threshold"
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold abc >/dev/null 2>&1; then
    _fail "Should reject non-numeric threshold"
else
    _pass "Rejects non-numeric threshold"
fi

# Test 4: Valid threshold 0
echo "Test 4: Accept threshold 0"
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 0 >/dev/null 2>&1; then
    _pass "Accepts threshold 0"
else
    _fail "Should accept threshold 0"
fi

# Test 5: JSON output format
echo "Test 5: JSON output format"
# 1063-nraf: `|| true` on every capture. validate-traces.sh exits 1 whenever
# coverage is below the threshold, and an unguarded assignment under this
# file's `set -euo pipefail` ABORTS the fixture mid-run — the operator sees a
# truncated log and no failing-test name, instead of a reported failure.
output=$(bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 80 2>/dev/null || true)
if [ "$JQ_AVAILABLE" -eq 0 ]; then
    _skip_jq "coverage_percentage arm"
elif printf '%s' "$output" | "${JQ_CMD[@]}" -e '.coverage_percentage' >/dev/null 2>&1; then
    _pass "JSON contains all required fields"
else
    _fail "JSON missing required fields"
fi

# Test 6: Status PASS when threshold met
echo "Test 6: Status PASS when coverage meets threshold"
status=""
[ "$JQ_AVAILABLE" -eq 1 ] && status=$(printf '%s' "$output" | "${JQ_CMD[@]}" -r '.status' 2>/dev/null || true)
if [ "$JQ_AVAILABLE" -eq 0 ]; then
    _skip_jq "status arm"
elif [[ "$status" == "PASS" ]]; then
    _pass "Correctly reports PASS status"
else
    _fail "Should report PASS when threshold met (got: $status)"
fi

# Test 7: Default threshold 90
echo "Test 7: Default threshold is 90"
output=$(bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 2>/dev/null || true)
threshold=""
[ "$JQ_AVAILABLE" -eq 1 ] && threshold=$(printf '%s' "$output" | "${JQ_CMD[@]}" -r '.threshold' 2>/dev/null || true)
if [ "$JQ_AVAILABLE" -eq 0 ]; then
    _skip_jq "default-threshold arm"
elif [[ "$threshold" == "90" ]]; then
    _pass "Default threshold is 90"
else
    _fail "Default threshold should be 90 (got: $threshold)"
fi

# Test 8: Exit code 0 when passing
echo "Test 8: Exit code 0 when passing"
if bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 0 >/dev/null 2>&1; then
    _pass "Exit code 0 when coverage meets threshold"
else
    _fail "Should exit 0 when coverage meets threshold"
fi

# Tests 9 and 10: the FAILURE path, driven by a SYNTHETIC TREE.
#
# ORDER 1069-c9w6 BROKE THESE ARMS AND EXPOSED WHY THEY WERE WRONG. They used
# to run `validate-traces.sh --coverage-threshold 100` against the LIVE
# checkout and require it to FAIL. That only ever passed because coverage was
# reported as 98%, and it was 98% because `grep -rl ... | grep -q .` under
# pipefail took SIGPIPE and recorded the three BEST-traced specs as uncovered.
# So these arms pinned the SYMPTOM OF A BUG as a contract: "this repo must
# never reach full trace coverage". Fixing the producer made real coverage
# 100%, no threshold in the valid range 0-100 can fail, and both arms went red.
#
# The deeper defect is that they asserted a property of the CHECKOUT rather
# than of the VALIDATOR. A synthetic root fixes that permanently: one spec
# traced, one spec not, so coverage is deterministically 50% regardless of what
# the real tree does. `--coverage-threshold 101` is NOT the fix — it is
# rejected as an invalid threshold before any coverage is computed, so it
# exercises argument validation and says nothing about the failure path.
_synthetic_root() {
    local t; t="$(mktemp -d)"
    mkdir -p "$t/scripts" "$t/openspec/specs/covered-spec" "$t/openspec/specs/uncovered-spec"
    cp "$SCRIPT_DIR/validate-traces.sh" "$t/scripts/"
    printf '# spec\n' > "$t/openspec/specs/covered-spec/spec.md"
    printf '# spec\n' > "$t/openspec/specs/uncovered-spec/spec.md"
    # exactly one trace, to the first spec only -> 1 of 2 covered = 50%
    # THE TRACE MARKER IS ASSEMBLED AT RUNTIME, never written literally here.
    # A literal trace marker naming a synthetic spec would be a GHOST TRACE to a
    # spec that does not exist, and the pre-commit ghost_check correctly flagged
    # exactly that on the first version of this block. It then flagged the
    # SECOND version too, because the comment explaining the hazard spelled the
    # marker out — the warning reproduced the defect it warned about. It is the same shape the
    # repo names elsewhere: a file that contains the string it is reasoning
    # about becomes a false positive for every scanner keyed on that string.
    printf '#!/usr/bin/env bash\n# @%s %s:%s\n' 'trace' 'spec' 'covered-spec' \
        > "$t/scripts/traced.sh"
    printf '%s' "$t"
}

echo "Test 9: Exit code 1 when coverage is below threshold"
_T9="$(_synthetic_root)"
if bash "$_T9/scripts/validate-traces.sh" --coverage-threshold 90 >/dev/null 2>&1; then
    _fail "Should exit non-zero when coverage (50%) is below the threshold (90)"
else
    _pass "Exit non-zero when coverage below threshold"
fi

echo "Test 10: Uncovered specs listed on failure"
_out="$(bash "$_T9/scripts/validate-traces.sh" --coverage-threshold 90 2>&1 || true)"
if printf '%s' "$_out" | grep -q "Uncovered specs"; then
    _pass "Lists uncovered specs when coverage fails"
else
    _fail "Should list uncovered specs when coverage fails"
fi

# POSITIVE CONTROL: the same synthetic tree must PASS a threshold it meets, so
# these arms cannot pass by the validator simply failing everything.
echo "Test 11: A met threshold passes on the same synthetic tree"
if bash "$_T9/scripts/validate-traces.sh" --coverage-threshold 50 >/dev/null 2>&1; then
    _pass "Exit zero when coverage meets the threshold"
else
    _fail "Should exit zero when coverage (50%) meets the threshold (50)"
fi
rm -rf "$_T9"

echo ""
echo "=== Test Summary ==="
echo "Passed: $passed"
echo "Failed: $failed"
echo ""

[[ $failed -eq 0 ]] && exit 0 || exit 1
