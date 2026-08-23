#!/usr/bin/env bash
# inject-negatives.sh — clone an index and append "declined alternative" chunks.
#
# THE HYPOTHESIS UNDER TEST. A retrieval system cannot refuse by similarity
# because in-corpus and near-miss score bands overlap. The proposal is to stop
# treating refusal as a threshold decision and make it a RETRIEVAL result: put
# the refusal in the corpus, so an out-of-corpus question retrieves a chunk that
# says so.
#
# For that to work the refusal chunk must out-score real content ON THAT
# QUESTION, and cosine similarity is TOPICAL. A generic "I don't know" chunk has
# no topic and will lose to everything. A chunk that says "Tillandsias does not
# use Helm; it deploys with podman and git mirrors" is topical about Helm and
# can win a Helm question — and, unlike a threshold, it returns something TRUE
# rather than merely withholding.
#
# ALIGNMENT IS THE HAZARD. chunks.jsonl and vectors.jsonl are LINE-POSITIONAL:
# line N of one belongs to line N of the other, with nothing in the file tying
# them together. A mis-joined append silently attaches every negative chunk's
# text to the wrong vector, and the result still loads, still retrieves, and is
# wrong in a way no schema check can see. So this asserts the count on both
# sides before and after, and refuses on any mismatch.
set -uo pipefail

SRC=""
DST=""
NEG=""
MODEL=""
ENDPOINT="${TILLANDSIAS_INFERENCE_ENDPOINT:-http://127.0.0.1:11434}"

while [ $# -gt 0 ]; do
    case "$1" in
        --src) SRC="$2"; shift 2 ;;
        --dst) DST="$2"; shift 2 ;;
        --negatives) NEG="$2"; shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        *) echo "error: unknown argument $1" >&2; exit 2 ;;
    esac
done
# `${v,,}` would be shorter and is bash-4-only; the macOS hosts run bash 3.2
# (761-g36m). A flag-name table costs three lines and runs everywhere.
require() { # require <value> <flag>
    [ -n "$1" ] || { echo "error: $2 required" >&2; exit 2; }
}
require "$SRC" --src
require "$DST" --dst
require "$NEG" --negatives
require "$MODEL" --model
[ -d "$SRC" ] || { echo "error: no such index: $SRC" >&2; exit 2; }

src_c="$(wc -l <"$SRC/chunks.jsonl")"
src_v="$(wc -l <"$SRC/vectors.jsonl")"
[ "$src_c" -eq "$src_v" ] || {
    echo "error: SOURCE index already misaligned: chunks=$src_c vectors=$src_v" >&2
    exit 1
}

rm -rf "$DST"
mkdir -p "$DST"
cp "$SRC/chunks.jsonl" "$DST/chunks.jsonl"
cp "$SRC/vectors.jsonl" "$DST/vectors.jsonl"

next_id="$src_c"
added=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    text="$(printf '%s' "$line" | jq -r '.text')"
    path="$(printf '%s' "$line" | jq -r '.path')"
    kind="$(printf '%s' "$line" | jq -r '.kind')"
    key="$(printf '%s' "$line" | jq -r '.key')"

    body="$(jq -nc --arg m "$MODEL" --arg i "$text" '{model:$m,input:$i}')"
    vec="$(curl -sS --fail-with-body -X POST "$ENDPOINT/v1/embeddings" \
        -H 'content-type: application/json' -d "$body" | jq -c '.data[0].embedding')"
    if [ -z "$vec" ] || [ "$vec" = null ]; then
        echo "error: embedding failed for negative chunk: $key" >&2
        exit 1
    fi

    jq -nc --argjson id "$next_id" --arg p "$path" --arg k "$kind" --arg key "$key" --arg t "$text" \
        '{id:$id,path:$p,kind:$k,key:$key,line_start:1,line_end:1,content_hash:"negative-case",text:$t}' \
        >>"$DST/chunks.jsonl"
    printf '%s\n' "$vec" >>"$DST/vectors.jsonl"
    next_id=$((next_id + 1))
    added=$((added + 1))
done <"$NEG"

dst_c="$(wc -l <"$DST/chunks.jsonl")"
dst_v="$(wc -l <"$DST/vectors.jsonl")"
[ "$dst_c" -eq "$dst_v" ] || {
    echo "error: RESULT misaligned: chunks=$dst_c vectors=$dst_v — index discarded" >&2
    rm -rf "$DST"
    exit 1
}
[ "$dst_c" -eq "$((src_c + added))" ] || {
    echo "error: expected $((src_c + added)) lines, got $dst_c — index discarded" >&2
    rm -rf "$DST"
    exit 1
}

# Positive proof of join, not just of count: the LAST chunk's vector must be the
# embedding of the LAST chunk's own text. Equal counts are satisfied by a
# perfectly shifted file, which is the failure this is here to catch.
last_text="$(tail -1 "$DST/chunks.jsonl" | jq -r '.text')"
probe="$(jq -nc --arg m "$MODEL" --arg i "$last_text" '{model:$m,input:$i}')"
expect="$(curl -sS -X POST "$ENDPOINT/v1/embeddings" -H 'content-type: application/json' \
    -d "$probe" | jq -c '.data[0].embedding')"
actual="$(tail -1 "$DST/vectors.jsonl")"
if [ "$expect" != "$actual" ]; then
    echo "error: last chunk's vector is NOT its own embedding — join is wrong, index discarded" >&2
    rm -rf "$DST"
    exit 1
fi

printf 'ok:inject-negatives: %s + %s = %s chunks, alignment and join verified\n' \
    "$src_c" "$added" "$dst_c"
