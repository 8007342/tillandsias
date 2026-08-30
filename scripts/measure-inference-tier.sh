#!/usr/bin/env bash
# @trace order:937-68n4
#
# measure-inference-tier.sh — take ONE inference measurement, or say plainly
# that no measurement was taken.
#
# WHY THIS EXISTS RATHER THAN A CURL ONE-LINER
#
# Every ad-hoc harness this cycle produced fluent nonsense before it produced a
# number. yoga's defaulted `mode=synthesized` and emitted six 6-millisecond
# "syntheses" from requests that failed while the server was starting — rows
# that would have entered the matrix as the fastest results in the experiment
# and dragged the completion-rate/grade crossover we are hunting. Mine, minutes
# after agreeing to guard against exactly that, printed `prefill 0 tok in 0.00s
# = 0.0 tok/s` four times from a script that could not open its own input.
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
# Output: one JSON object per invocation on stdout. Always exactly one.
#   mode=error       no measurement was taken; `error` says why
#   mode=synthesized the model produced an answer within budget
#   mode=retrieval-only  the pipeline fell back to its documented floor
set -uo pipefail

ENDPOINT="${TILLANDSIAS_MEASURE_ENDPOINT:-http://127.0.0.1:11436/v1/chat/completions}"
MODEL="${1:-methodology}"
QUERY="${2:-what is the pre-push gate rule for non-linux-next branches?}"
TIMEOUT="${TILLANDSIAS_MEASURE_TIMEOUT:-300}"

emit_error() {
    # Note the absent fields are absent, not zero. A zero here would be a
    # measurement claim; there is no measurement.
    printf '{"mode":"error","error":%s,"model":%s}\n' \
        "$(printf '%s' "$1" | python -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
        "$(printf '%s' "$MODEL" | python -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
    exit 0
}

body="$(python - "$MODEL" "$QUERY" <<'PY'
import json, sys
print(json.dumps({"model": sys.argv[1],
                  "messages": [{"role": "user", "content": sys.argv[2]}]}))
PY
)" || emit_error "could not build the request body"

# Milliseconds via python, NOT `date +%s%3N`. That is a GNU-date-ism: BSD date
# does not fail on it, it SUCCEEDS and prints garbage, so every wall_ms this
# script produced on a macOS host would have been a confident wrong number with
# no error anywhere. Caught by check-bash-dialect, which is the same failure
# class this script exists to refuse — a measurement tool emitting fluent
# nonsense — found in the measurement tool itself.
now_ms() { python -c 'import time; print(int(time.time()*1000))'; }
start_ms=$(now_ms)
resp="$(curl -sS --max-time "$TIMEOUT" -X POST "$ENDPOINT" \
        -H 'Content-Type: application/json' -d "$body" 2>/dev/null)"
curl_rc=$?
end_ms=$(now_ms)

# GUARD 1 — the request itself. A non-zero curl is not a slow answer.
[ "$curl_rc" -eq 0 ] || emit_error "curl exit $curl_rc (timeout, refused, or transport failure)"
# GUARD 2 — an empty body is not an empty answer.
[ -n "$resp" ] || emit_error "empty response body"

# GUARDS 3 and 4 — parseable JSON, and content that is actually present.
# Done in one pass so a malformed response cannot reach the classifier.
#
# The response travels through a FILE, not stdin. `python - <<PY` already uses
# stdin for the program text, so a piped response is read as EMPTY — which is
# how the first version of this script reported "response is not JSON" for a
# perfectly good 3071-byte reply. Worth keeping the note: the guard behaved
# correctly (an error row, not a fabricated one) while the bug was mine, one
# layer up. A harness that refuses to guess tells you when it is broken.
resp_file="$(mktemp)"
trap 'rm -f "$resp_file"' EXIT
printf '%s' "$resp" > "$resp_file"
python - "$((end_ms - start_ms))" "$MODEL" "$resp_file" <<'PY'
import json, sys

wall_ms = int(sys.argv[1])
model = sys.argv[2]
raw = open(sys.argv[3], encoding="utf-8").read()

def bail(msg):
    print(json.dumps({"mode": "error", "error": msg, "model": model}))
    sys.exit(0)

try:
    v = json.loads(raw)
except Exception as e:
    bail(f"response is not JSON: {e}")

if "error" in v:
    bail(f"endpoint returned an error object: {v['error']}")

try:
    content = v["choices"][0]["message"]["content"]
except Exception:
    bail("response carried no choices[0].message.content")

if not content.strip():
    bail("completion content was empty")

env = v.get("tillandsias_envelope") or {}
# The classifier reads the answer, and only ever runs on content that exists.
# It has no default: an unrecognised shape is an error, not a synthesis.
if "synthesis timed out" in content:
    mode = "retrieval-only"
elif content.startswith("unsupported: "):
    mode = "refused"
else:
    mode = "synthesized"

cits = env.get("citations") or []
print(json.dumps({
    "mode": mode,
    "model": model,
    "wall_ms": wall_ms,
    "confidence": env.get("confidence"),
    "citation_count": len(cits),
    "top_citation": (f"{cits[0]['path']}:{cits[0].get('line_start')}" if cits else None),
    "content_chars": len(content),
    "rag_source_commit": v.get("rag_source_commit"),
}))
PY
