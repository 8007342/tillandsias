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

# THE SYNTHETIC ROOT, AND WHY ALMOST EVERY ARM NOW USES IT.
#
# ORDER 1069-c9w6 BROKE TESTS 9 AND 10 AND EXPOSED WHY THEY WERE WRONG. They
# used to run `validate-traces.sh --coverage-threshold 100` against the LIVE
# checkout and require it to FAIL. That only ever passed because coverage was
# reported as 98%, and it was 98% because `grep -rl ... | grep -q .` under
# pipefail took SIGPIPE and recorded the three BEST-traced specs as uncovered.
# So these arms pinned the SYMPTOM OF A BUG as a contract: "this repo must
# never reach full trace coverage". Fixing the producer made real coverage
# 100%, no threshold in the valid range 0-100 can fail, and both arms went red.
#
# The deeper defect is that they asserted a property of the CHECKOUT rather
# than of the VALIDATOR. `--coverage-threshold 101` is NOT the fix — it is
# rejected as an invalid threshold before any coverage is computed, so it
# exercises argument validation and says nothing about the failure path.
#
# 1077-vzwq: I FIXED TWO ARMS AND LEFT THE PRINCIPLE HALF-APPLIED. Tests 5, 6
# and 7 still drove the live checkout, and Test 6 required
# `--coverage-threshold 80` to report PASS — an undeclared 80% coverage FLOOR
# on the real tree, wired into --check on all three hosts under an arm named
# "Status PASS when coverage meets threshold". Coverage is 100% today, so it
# had 20 points of headroom and would have gone red only later; and a red would
# have been TRUE but diagnosed wrongly, because an operator reading "Test 6
# failed" looks for a broken validator, not a coverage regression. The trigger
# is not only losing annotations — adding ~36 spec directories ahead of their
# code does it too, which is a normal OpenSpec-driven shape.
#
# So the synthetic root is built ONCE and every arm asserting a property of the
# VALIDATOR runs against it: one spec traced, one not, coverage deterministically
# 50% regardless of the real tree. Exactly one arm (Test 8) still touches the
# real checkout, deliberately — a validator that crashes on the real repo is a
# real defect and nothing else would catch it — and it uses threshold 0, which
# no coverage figure can fail, so it cannot smuggle a floor back in.
#
# It is also most of the fixture's cost. Each live coverage run spawns ~177
# basename calls plus 177 recursive greps over scripts/crates/images/methodology,
# and there were five of them.
_synthetic_root() {
    local t; t="$(mktemp -d)"
    # 1077-vzwq: CREATE EVERY SEARCH ROOT validate-traces.sh:264-266 GREPS.
    # Omitting crates/ images/ methodology/ and the root *.sh made the
    # "uncovered" verdict arrive by grep rc=2 (ERROR: unreadable operands)
    # rather than rc=1 (no match) — MEASURED, both ways: rc 2 with the dirs
    # missing, rc 1 with them present. So Tests 6 and 11, which are credited
    # with guarding the SIGPIPE regression this whole file was rewritten
    # around, were firing on an error path that cannot occur in a real tree.
    # A control that reds for a mechanism the defect does not use is not a
    # control.
    mkdir -p "$t/scripts" "$t/crates" "$t/images" "$t/methodology" \
             "$t/openspec/specs/covered-spec" "$t/openspec/specs/uncovered-spec"
    : > "$t/root.sh"
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

echo "=== Trace Coverage Threshold Tests ==="
echo ""

_SYNTH="$(_synthetic_root)"
# 1077-vzwq: the synthetic root used to be removed by a straight-line `rm -rf`
# at the end, so any interrupt between creation and that line leaked a mktemp
# dir. Sibling fixtures use a trap; so does this one now.
trap 'rm -rf "$_SYNTH"' EXIT
_V="$_SYNTH/scripts/validate-traces.sh"

# 1077-vzwq: PIN THE RATIO THE OTHER ARMS ASSUME. Five arms compare against 50
# or 90 and are correct only while the synthetic tree is 1-traced-of-2. That
# ratio lived in a comment, so an edit to _synthetic_root would silently change
# what those arms mean while every one of them stayed green. jq-free on purpose:
# this must hold on a host with no jq, where the arms that check it are skipped.
_ratio="$(bash "$_V" --coverage-threshold 0 2>/dev/null || true)"
if grep -q '"coverage_percentage": 50' <<<"$_ratio" \
   && grep -q '"total_active_specs": 2' <<<"$_ratio"; then
    _pass "synthetic tree is 1-traced-of-2 (50%), as the arms below assume"
else
    _fail "synthetic tree is NOT 50%/2 specs — every threshold below is meaningless: $(printf '%s' "$_ratio" | tr -d '\n')"
fi

# 1077-vzwq: ASSERT THE DIAGNOSTIC, NOT MERELY A NON-ZERO EXIT. Tests 2 and 3
# were mutation-insensitive: deleting validate-traces.sh's entire threshold
# validation block killed only Test 1. Test 2 (`101`) still "passed" because
# with validation gone `[[ 50 -ge 101 ]]` is false and the validator exits 1
# anyway — it could not distinguish "rejected an out-of-range threshold" from
# "coverage below threshold", and never could, since coverage cannot exceed 101.
# Test 3 (`abc`) still "passed" because an unvalidated non-numeric threshold
# dies on set -u — it detected a crash, not a rejection. Matching the message
# is what separates the three.
_expect_invalid_threshold() {
    local _rc=0 _out=""
    _out="$(bash "$_V" --coverage-threshold "$1" 2>&1)" || _rc=$?
    if [ "$_rc" -eq 0 ]; then
        _fail "$2: should have been rejected"
    elif grep -q "Invalid threshold: $1" <<<"$_out"; then
        _pass "$2, and names it as an invalid threshold"
    else
        _fail "$2: rejected, but not AS an invalid threshold (first line: $(head -1 <<<"$_out"))"
    fi
}

echo "Test 1: Reject negative threshold"
_expect_invalid_threshold -1 "Rejects negative threshold"

echo "Test 2: Reject threshold > 100"
_expect_invalid_threshold 101 "Rejects threshold > 100"

echo "Test 3: Reject non-numeric threshold"
_expect_invalid_threshold abc "Rejects non-numeric threshold"

# Test 4: Valid threshold 0
echo "Test 4: Accept threshold 0"
if bash "$_V" --coverage-threshold 0 >/dev/null 2>&1; then
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
output=$(bash "$_V" --coverage-threshold 50 2>/dev/null || true)
if [ "$JQ_AVAILABLE" -eq 0 ]; then
    _skip_jq "coverage_percentage arm"
elif printf '%s' "$output" | "${JQ_CMD[@]}" -e '.coverage_percentage' >/dev/null 2>&1; then
    _pass "JSON contains all required fields"
else
    _fail "JSON missing required fields"
fi

# Test 6: Status PASS when threshold met
# The threshold is 50 against a tree that is deterministically 50% covered, so
# this asserts the IMPLICATION (coverage >= threshold => PASS) rather than the
# real repo's coverage.
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
output=$(bash "$_V" --coverage-threshold 2>/dev/null || true)
threshold=""
[ "$JQ_AVAILABLE" -eq 1 ] && threshold=$(printf '%s' "$output" | "${JQ_CMD[@]}" -r '.threshold' 2>/dev/null || true)
if [ "$JQ_AVAILABLE" -eq 0 ]; then
    _skip_jq "default-threshold arm"
elif [[ "$threshold" == "90" ]]; then
    _pass "Default threshold is 90"
else
    _fail "Default threshold should be 90 (got: $threshold)"
fi

# Test 8: THE ONLY LIVE ARM.
# 1077-vzwq: this used to be a byte-identical duplicate of Test 4 — same
# invocation, same expectation, a different label. Repurposed into the one
# thing the synthetic root genuinely cannot cover: that the validator survives
# the REAL checkout and produces a report there. Threshold 0 is unfailable on
# coverage, so this asserts liveness without re-introducing a floor. Deliberately
# jq-free, so it still runs on a host with no jq.
echo "Test 8: Validator runs to completion on the REAL checkout"
_live_rc=0
_live_out="$(bash "$SCRIPT_DIR/validate-traces.sh" --coverage-threshold 0 2>/dev/null)" || _live_rc=$?
# 1077-vzwq: ASSERT A CORRECTNESS RELATION, NOT A NUMBER. Greping for the field
# NAME let the validator report any denominator it liked: hardcoding
# TOTAL_ACTIVE_SPECS=2 left every arm green, because the synthetic tree really
# does have 2 specs and this arm never looked at the value. The denominator must
# equal the number of spec directories that exist — a relation the fixture can
# check without CHOOSING a number, so it can never become a coverage floor. This
# is the distinction the whole repair rests on: comparing against the live tree
# is fine when the comparison is a correctness property; it is a landmine only
# when the comparison is to an unchosen constant.
_specs_on_disk="$(find "$ROOT/openspec/specs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d '[:space:]')"
_live_total="$(sed -n 's/.*"total_active_specs":[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$_live_out")"
if [ "$_live_rc" -ne 0 ]; then
    _fail "Should exit 0 on the real tree at threshold 0 (rc=$_live_rc) — if openspec/specs is absent this is the checkout, not the validator"
elif ! grep -q '"coverage_percentage"' <<<"$_live_out"; then
    _fail "Ran on the real tree but emitted no coverage_percentage field"
elif [ -z "$_live_total" ]; then
    _fail "Ran on the real tree but emitted no total_active_specs field"
elif [ "$_live_total" != "$_specs_on_disk" ]; then
    _fail "The validator counted $_live_total active specs; $_specs_on_disk spec directories exist — the denominator is wrong, so every percentage it reports is wrong"
else
    _pass "Runs on the real tree and its denominator matches the $_specs_on_disk spec directories that exist"
fi

# 1077-vzwq: rc == 1 SPECIFICALLY, not merely non-zero. The `else` branch
# greened on ANY failure, so a crash on the failure path — or the rc 141 a
# SIGPIPE produces, which is the exact signal shape this validator's last bug
# emitted — certified "exit non-zero when coverage below threshold" while the
# validator was not reaching that conclusion at all.
echo "Test 9: Exit code 1 when coverage is below threshold"
_t9_rc=0
bash "$_V" --coverage-threshold 90 >/dev/null 2>&1 || _t9_rc=$?
if [ "$_t9_rc" -eq 1 ]; then
    _pass "Exit code is exactly 1 when coverage below threshold"
else
    _fail "Should exit 1 when coverage (50%) is below the threshold (90), got rc=$_t9_rc"
fi

# 1077-vzwq: ASSERT THE LISTING, NOT THE BANNER. This grepped only the header
# string "Uncovered specs", so deleting the per-spec loop entirely, or listing
# the COVERED spec instead of the uncovered one, both left it green — and a
# crash immediately after the header printed the banner, listed nothing, and
# still greened both this arm and Test 9. Name the spec, require the covered one
# to be absent, and require the trailer that only a completed run emits.
echo "Test 10: Uncovered specs listed on failure"
_out="$(bash "$_V" --coverage-threshold 90 2>&1 || true)"
if ! grep -q "Uncovered specs" <<<"$_out"; then
    _fail "Should print the uncovered-specs banner when coverage fails"
elif ! grep -qE '^[[:space:]]*-[[:space:]]*uncovered-spec$' <<<"$_out"; then
    _fail "Banner printed but the uncovered spec is not NAMED — a banner is not a listing"
elif grep -qE '^[[:space:]]*-[[:space:]]*covered-spec$' <<<"$_out"; then
    _fail "The TRACED spec is listed as uncovered — the listing is inverted"
elif ! grep -q "Action: Add @trace spec:uncovered-spec" <<<"$_out"; then
    _fail "No action trailer — the run did not reach the end of the failure path"
else
    _pass "Names the uncovered spec, omits the covered one, and completes the failure path"
fi

# POSITIVE CONTROL: the same synthetic tree must PASS a threshold it meets, so
# these arms cannot pass by the validator simply failing everything.
echo "Test 11: A met threshold passes on the same synthetic tree"
if bash "$_V" --coverage-threshold 50 >/dev/null 2>&1; then
    _pass "Exit zero when coverage meets the threshold"
else
    _fail "Should exit zero when coverage (50%) meets the threshold (50)"
fi

echo ""
echo "=== Test Summary ==="
echo "Passed: $passed"
echo "Failed: $failed"
echo ""

[[ $failed -eq 0 ]] && exit 0 || exit 1
