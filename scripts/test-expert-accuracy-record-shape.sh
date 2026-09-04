#!/usr/bin/env bash
# @trace order:917-6iwv
#
# test-expert-accuracy-record-shape.sh — pin the negative controls of
# record-expert-accuracy.sh.
#
# WHY THIS TEST EXISTS AND WHAT IT IS DEFENDING
#
# 917-6iwv names one regression explicitly: this codebase has SHIPPED
# `expert_accuracy rate=100%` in the same run as
# `verdict:attention:expert-answered-nothing-check-base-branch`, and later
# reported `experts-never-called` against an empty usage log (911-m7js lineage).
# The packet says a repeat is a REGRESSION, not a new bug. A number that cannot
# distinguish "answered correctly" from "was never asked" is worse than none.
#
# So the properties under test are not "the arithmetic is right". They are:
#
#   1. Nothing graded NEVER renders as a rate — not 100, not 0, but null.
#   2. A partially-exercised host is DISTINGUISHABLE from a complete one even
#      when its rate is 100%, because status, denominator and the names of the
#      unexercised engines all travel with it.
#   3. The denominator is always present, so no consumer can read a rate
#      without seeing what it is over.
#
# Property 2 is the subtle one and the reason this file is not just an
# assert-93%: the historical defect did not print a WRONG number, it printed a
# number whose scope was undisclosed. `rate=100%` over 28 graded of 33 is TRUE.
# It is only safe because `status=partial` and `skipped_engines` are beside it.
#
# The fixture supplies the grader's result line directly (see the FIXTURE SEAM
# in the script under test), because a stale index-dir override does NOT force a
# skip — measured on lenovinha 2026-09-04, an empty override still graded 33/33.
# A test that tried to provoke the skip through the environment would silently
# test nothing, which is the failure mode it is meant to catch.

set -uo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

REC="$REPO_ROOT/scripts/record-expert-accuracy.sh"
fails=0
_t() {
    _name="$1"; _line="$2"; _filter="$3"; _want="$4"
    _got="$(TILLANDSIAS_EXPERT_ACCURACY_GRADE_LINE="$_line" \
        "$REC" --dry-run 2>/dev/null | jq -c "$_filter" 2>/dev/null)"
    if [ "$_got" = "$_want" ]; then
        echo "PASS  $_name"
    else
        echo "FAIL  $_name"
        echo "        want: $_want"
        echo "        got:  ${_got:-<no output>}"
        fails=$((fails+1))
    fi
}

if ! command -v jq >/dev/null 2>&1; then
    echo "skip:test-expert-accuracy-record-shape:jq-absent"
    exit 0
fi
if [ ! -x "$REC" ]; then
    echo "fail:test-expert-accuracy-record-shape:script-missing-or-not-executable"
    exit 1
fi

# 1. NOTHING GRADED IS NEVER A RATE. This is the control the packet says to
#    defend hardest. null, not 0 and not 100.
_t "never-called renders a null rate, not 0 and not 100" \
   "groundtruth-result: sets=4 total=33 pass=0 fail=0 skipped=33 skipped_engines=spec.answer elapsed_ms=12" \
   '{status,graded,validated_rate_pct}' \
   '{"status":"never-called","graded":0,"validated_rate_pct":null}'

# 2. A 100% RATE ON A PARTIAL RUN STAYS DISTINGUISHABLE. This is the exact
#    historical shape: every graded case passed, and five never ran.
_t "partial run carries status, denominator and the unexercised engine" \
   "groundtruth-result: sets=4 total=33 pass=28 fail=0 skipped=5 skipped_engines=spec.answer elapsed_ms=2664" \
   '{status,graded,total,skipped,skipped_engines,validated_rate_pct}' \
   '{"status":"partial","graded":28,"total":33,"skipped":5,"skipped_engines":["spec.answer"],"validated_rate_pct":100}'

# 3. A fully graded run says so, and only then may `graded` equal `total`.
_t "fully graded run reports status=graded with graded==total" \
   "groundtruth-result: sets=4 total=33 pass=31 fail=2 skipped=0 elapsed_ms=6322" \
   '{status,graded,total,skipped,validated_rate_pct}' \
   '{"status":"graded","graded":33,"total":33,"skipped":0,"validated_rate_pct":93}'

# 4. ESTIMATED IS NULL UNTIL SOMETHING PRODUCES ONE. 917-6iwv asks for estimated
#    VS validated; writing an invented estimate would collapse two columns that
#    exist precisely to disagree.
_t "estimated accuracy is null, never inferred from the validated number" \
   "groundtruth-result: sets=4 total=33 pass=31 fail=2 skipped=0 elapsed_ms=6322" \
   '{estimated_rate_pct}' \
   '{"estimated_rate_pct":null}'

# 5. A fixture-sourced record is MARKED, so a harvest can never count one as a
#    measurement.
_t "fixture-sourced records are labelled source=fixture" \
   "groundtruth-result: sets=4 total=33 pass=31 fail=2 skipped=0 elapsed_ms=6322" \
   '{source}' \
   '{"source":"fixture"}'

# 6. The host is identified. forge-expert-health.jsonl records "host":"unknown"
#    while derive-host-identity.sh sits in the same directory; a per-host series
#    with no host cannot be harvested across hosts at all.
_got_host="$(TILLANDSIAS_EXPERT_ACCURACY_GRADE_LINE="groundtruth-result: sets=1 total=1 pass=1 fail=0 skipped=0 elapsed_ms=1" \
    "$REC" --dry-run 2>/dev/null | jq -r '.host' 2>/dev/null)"
if [ -n "$_got_host" ] && [ "$_got_host" != "unknown" ] && [ "$_got_host" != "null" ]; then
    echo "PASS  record carries a resolved host identity ($_got_host)"
else
    echo "FAIL  record carries a resolved host identity"
    echo "        got: ${_got_host:-<none>}"
    fails=$((fails+1))
fi

if [ "$fails" -eq 0 ]; then
    echo "ok:test-expert-accuracy-record-shape:6-passed"
    exit 0
fi
echo "fail:test-expert-accuracy-record-shape:${fails}-failed"
exit 1
