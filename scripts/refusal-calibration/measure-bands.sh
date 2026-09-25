#!/usr/bin/env bash
# measure-bands.sh — embed a labelled question set, retrieve top-2, emit TSV.
#
# One row per question:
#   band  corpus  top1  top2  margin  top1_kind  top1_path  question
#
# The index and the query MUST be embedded by the SAME model — cosine between
# vectors from different embedders is meaningless, not merely noisy. The caller
# passes both and this script does not guess.
set -uo pipefail

_mb_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_mb_dir" ] && [ "$_mb_dir" != "/" ] && [ ! -f "$_mb_dir/lib/tool-dispatch.sh" ]; do
    _mb_dir="$(dirname "$_mb_dir")"
done
if [ -f "$_mb_dir/lib/tool-dispatch.sh" ]; then
    . "$_mb_dir/lib/tool-dispatch.sh" 2>/dev/null || true
    . "$_mb_dir/lib/tool-materialize.sh" 2>/dev/null || true
fi
if command -v fast_tool >/dev/null 2>&1; then
    JQ="$(fast_tool jq || printf 'jq')"
else
    JQ="jq"
fi

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/plan-binary-probe.sh"
if ! PLAN="$(resolve_plan_binary)"; then
    echo "fail:measure-bands:no-runnable-plan-binary" >&2
    exit 2
fi
ENDPOINT="${TILLANDSIAS_INFERENCE_ENDPOINT:-http://127.0.0.1:11434}"
MODEL=""
INDEX_DIR=""
QFILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --model) MODEL="$2"; shift 2 ;;
        --index-dir) INDEX_DIR="$2"; shift 2 ;;
        --questions) QFILE="$2"; shift 2 ;;
        *) echo "error: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$MODEL" ] || { echo "error: --model required" >&2; exit 2; }
[ -n "$INDEX_DIR" ] || { echo "error: --index-dir required" >&2; exit 2; }
[ -n "$QFILE" ] || { echo "error: --questions required" >&2; exit 2; }
[ -d "$INDEX_DIR" ] || { echo "error: no such index dir: $INDEX_DIR" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bands.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

printf 'band\tcorpus\ttop1\ttop2\tmargin\ttop1_kind\ttop1_path\tquestion\n'

n=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    band="$(printf '%s' "$line" | "$JQ" -r '.band')"
    corpus="$(printf '%s' "$line" | "$JQ" -r '.corpus')"
    q="$(printf '%s' "$line" | "$JQ" -r '.q')"

    # Embed. A failure here must NOT silently become a zero score — an
    # unembeddable question that scores 0.0 would land in the refuse band and
    # look like a success.
    # QUERY PREFIX (864-p2rk) — the counterpart to TILLANDSIAS_EMBED_DOC_PREFIX
    # in spec-index-ensure.sh. Must match the convention the index was BUILT
    # with, or query and passage land in different halves of an asymmetric
    # space and every score is meaningless. Empty by default, reproducing every
    # historical measurement exactly.
    body="$("$JQ" -nc --arg m "$MODEL" --arg i "${TILLANDSIAS_EMBED_QUERY_PREFIX:-}$q" '{model:$m,input:$i}')"
    resp="$(curl -sS --fail-with-body -X POST "$ENDPOINT/v1/embeddings" \
        -H 'content-type: application/json' -d "$body" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'EMBED-FAIL\t%s\t\t\t\t\t\t%s\n' "$corpus" "$q" >&2
        continue
    fi
    printf '%s' "$resp" | "$JQ" -c '.data[0].embedding' >"$TMP/qv.json" 2>/dev/null
    if [ ! -s "$TMP/qv.json" ] || [ "$(cat "$TMP/qv.json")" = null ]; then
        printf 'EMBED-EMPTY\t%s\t\t\t\t\t\t%s\n' "$corpus" "$q" >&2
        continue
    fi

    # spec-retrieve emits a JSON ARRAY. PARSE it — an awk column grab over
    # pretty-printed JSON silently reads brace lines as data (752-pst5), which
    # is what the first draft of this harness did.
    out="$("$PLAN" spec-retrieve --index-dir "$INDEX_DIR" --query-vec "$TMP/qv.json" --k 2 2>/dev/null)"
    t1="$(printf '%s' "$out" | "$JQ" -r '.[0].score // empty')"
    t2="$(printf '%s' "$out" | "$JQ" -r '.[1].score // empty')"
    k1="$(printf '%s' "$out" | "$JQ" -r '.[0].kind // "?"')"
    p1="$(printf '%s' "$out" | "$JQ" -r '.[0].path // "?"')"
    [ -n "$t1" ] || { printf 'RETRIEVE-FAIL\t%s\t\t\t\t\t\t%s\n' "$corpus" "$q" >&2; continue; }
    [ -n "$t2" ] || t2="$t1"
    margin="$(awk -v a="$t1" -v b="$t2" 'BEGIN{printf "%.4f", a-b}')"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$band" "$corpus" "$t1" "$t2" "$margin" "$k1" "$p1" "$q"
    n=$((n + 1))
done <"$QFILE"

printf 'measured %s questions with %s\n' "$n" "$MODEL" >&2
