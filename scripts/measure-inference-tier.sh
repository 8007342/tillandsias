#!/usr/bin/env bash
# @trace order:937-68n4
#
# measure-inference-tier.sh — take ONE inference measurement, or say plainly
# that no measurement was taken.
#
# WHY THIS EXISTS RATHER THAN A CURL ONE-LINER
#
# Every ad-hoc harness in the 937-68n4 cycle produced fluent nonsense before it
# produced a number. yoga's defaulted `mode=synthesized` and emitted six
# 6-millisecond "syntheses" from requests that failed while the server was
# starting — rows that would have entered the matrix as the fastest results in
# the experiment. Mine, minutes after agreeing to guard against exactly that,
# printed `0.0 tok/s` four times from a script that could not open its own input.
#
# Neither errored. Both answered. That is the shape: the failure mode of a
# measurement tool is not silence, it is fluency.
#
# So the contract here is that a row is EITHER a measurement or an explicit
# error carrying its reason, and never a default standing in for one. An error
# row is an ABSENCE OF DATA, not a data point: it is excluded from rates rather
# than counted as a failure, because "3 of 10 requests never happened" and "3 of
# 10 requests failed to synthesize" are different claims and only one of them is
# about the model.
#
# NO PYTHON, AND NO SHELL CLOCK. The first version of this script used python
# for JSON and `date +%s%3N` for timing. Both were wrong and the fleet's own
# guards said so: python is forbidden in every environment
# (check-no-python-scripts.sh), and `date +%s%3N` is a GNU-ism that BSD date
# ACCEPTS while emitting garbage, so a macOS host would have produced confident
# wrong wall times with nothing erroring (761-g36m / 784-dwkh).
#
# Timing is therefore curl's own %{time_total}, following the precedent in
# bench-accel-lane.sh:133 — portable, and the better instrument anyway: it
# measures the REQUEST, excluding the jq and process-spawn overhead a shell-side
# timestamp folds into every sample. JSON is jq in both directions.
#
# Output: one JSON object per invocation on stdout. Always exactly one.
#   mode=error           no measurement was taken; `error` says why
#   mode=synthesized     the model produced an answer within budget
#   mode=retrieval-only  the pipeline fell back to its documented floor
#   mode=refused         a typed `unsupported:` refusal
set -uo pipefail

ENDPOINT="${TILLANDSIAS_MEASURE_ENDPOINT:-http://127.0.0.1:11436/v1/chat/completions}"
MODEL="${1:-methodology}"
QUERY="${2:-what is the pre-push gate rule for non-linux-next branches?}"
TIMEOUT="${TILLANDSIAS_MEASURE_TIMEOUT:-300}"

command -v jq >/dev/null 2>&1 || {
    printf '{"mode":"error","error":"jq is required and is not on PATH"}\n'
    exit 0
}

work="$(mktemp -d)" || {
    printf '{"mode":"error","error":"could not create a work directory"}\n'
    exit 0
}
trap 'rm -rf "$work"' EXIT

emit_error() {
    # The absent fields are ABSENT, not zero. A zero wall_ms here would be a
    # measurement claim, and there is no measurement.
    jq -nc --arg e "$1" --arg m "$MODEL" '{mode:"error", error:$e, model:$m}'
    exit 0
}

jq -nc --arg m "$MODEL" --arg q "$QUERY" \
    '{model:$m, messages:[{role:"user", content:$q}]}' > "$work/req.json" \
    || emit_error "could not build the request body"

# %{time_total} and the body come from ONE request — timing a second call would
# measure a different request than the one being classified.
secs="$(curl -sS --max-time "$TIMEOUT" -o "$work/resp.json" -w '%{time_total}' \
        -X POST "$ENDPOINT" -H 'Content-Type: application/json' \
        -d @"$work/req.json" 2>/dev/null)"
curl_rc=$?

# GUARD 1 — the request itself. A non-zero curl is not a slow answer.
[ "$curl_rc" -eq 0 ] || emit_error "curl exit $curl_rc (timeout, refused, or transport failure)"
# GUARD 2 — an empty body is not an empty answer.
[ -s "$work/resp.json" ] || emit_error "empty response body"
# GUARD 3 — parseable JSON.
jq -e type "$work/resp.json" >/dev/null 2>&1 || emit_error "response is not JSON"
# GUARD 4 — an endpoint-level error object is not a completion.
if jq -e 'has("error")' "$work/resp.json" >/dev/null 2>&1; then
    emit_error "endpoint returned an error object: $(jq -rc '.error' "$work/resp.json")"
fi
# GUARD 5 — content that is actually present. The classifier only ever runs on
# a body that reached here, so it has no default to fall back to.
jq -e '.choices[0].message.content | type == "string" and (length > 0)' \
    "$work/resp.json" >/dev/null 2>&1 \
    || emit_error "response carried no non-empty choices[0].message.content"

# GUARD 6 — the answer must be an ANSWER, not merely a non-empty string.
#
# Guards 1-5 all verify that the MEASUREMENT happened: the request went out,
# a body came back, it parsed, it was not an error object, it carried content.
# Every one of them passes for a model emitting token soup. On 2026-08-30 this
# host benchmarked Qwen2.5-0.5B-Instruct-Hybrid at a plausible 52.92 tok/s over
# three consistent reps with finish_reason "stop" and exact completion_tokens,
# while the model was returning "#, or ahtewek..." — a fully well-formed
# measurement of a model that was not doing the task. A throughput figure from
# an arm that cannot answer is not a slow measurement; it is not a measurement.
#
# So: when TILLANDSIAS_TIER_ASSERT is set, the content must contain it
# (case-insensitively) or the whole run is REFUSED rather than reported. The
# assertion is checked on the SAME response that produced the timing above —
# never a second call. A control taken in a separate invocation can describe a
# different process state than the one being measured, which is how a stale
# control has already misled this fleet more than once.
if [ -n "${TILLANDSIAS_TIER_ASSERT:-}" ]; then
    jq -e --arg want "$TILLANDSIAS_TIER_ASSERT" \
        '(.choices[0].message.content | ascii_downcase)
         | contains($want | ascii_downcase)' \
        "$work/resp.json" >/dev/null 2>&1 \
        || emit_error "correctness assertion failed: the response does not contain '${TILLANDSIAS_TIER_ASSERT}' — the arm answered, but not the question (no number is reported for an arm that is not doing the task)"
fi

wall_ms="$(awk -v s="${secs:-0}" 'BEGIN { printf "%d\n", (s * 1000) + 0.5 }')"

jq -c --argjson wall "$wall_ms" --arg model "$MODEL" '
    (.choices[0].message.content) as $c
  | (.tillandsias_envelope // {}) as $env
  | ($env.citations // []) as $cits
  | {
      mode:
        (if   ($c | contains("synthesis timed out")) then "retrieval-only"
         elif ($c | startswith("unsupported: "))     then "refused"
         else "synthesized" end),
      model:             $model,
      wall_ms:           $wall,
      confidence:        ($env.confidence // null),
      citation_count:    ($cits | length),
      top_citation:      (if ($cits | length) > 0
                          then ($cits[0].path + ":" + (($cits[0].line_start // 0) | tostring))
                          else null end),
      content_chars:     ($c | length),
      rag_source_commit: (.rag_source_commit // null)
    }' "$work/resp.json" 2>/dev/null \
  || emit_error "could not project the response fields"
