#!/usr/bin/env bash
# measure-recall-at-k.sh — separate RETRIEVAL RECALL from JUDGE QUALITY.
#
# WHY THIS EXISTS. Tier B measured at k=1 reported in-corpus SUPPORTED at 20%
# and that number meant nothing, because it multiplied two things together: my
# label says SOME FILE in the repo answers the question, while the judge is
# asked whether THIS RETRIEVED PASSAGE does. Those differ every time top-1 is
# wrong-but-plausible. Re-judging the refusals against the recorded source file
# flipped 6 of 10 to YES — the judge had been right and top-1 had simply missed.
#
# So this measures the two separately:
#   recall@k     did ANY of the top-k passages get judged SUPPORTED?
#   judge@source did the judge say YES about a passage KNOWN to answer?
# The first is a property of retrieval, the second of the judge, and only their
# product was ever visible before.
#
# TWO PHASES, AND THE SPLIT IS NOT COSMETIC. Retrieval needs the embedder and
# judging needs the generative model; holding both resident is precisely the
# condition that aborts a load on this host (849-tz8g, measured: 7,910 MiB
# resident across two models, a third load dies with GGML_ASSERT while sixteen
# gigabytes are free). Phase 1 embeds and unloads; phase 2 judges. Serialising
# is the proven workaround, so this script demonstrates it rather than
# describing it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/plan-binary-probe.sh"
if ! PLAN="$(ensure_fresh_plan_binary)"; then
    echo "fail:recall-at-k:no-fresh-plan-binary" >&2
    exit 2
fi

ENDPOINT="${TILLANDSIAS_INFERENCE_ENDPOINT:-http://127.0.0.1:11434}"
EMBED_MODEL="${TILLANDSIAS_EMBED_MODEL:-nomic-embed-text}"
JUDGE_MODEL="${TILLANDSIAS_JUDGE_MODEL:-qwen2.5:7b}"
K="${TILLANDSIAS_RECALL_K:-5}"
INDEX_DIR=""
QUESTIONS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --index-dir) INDEX_DIR="$2"; shift 2 ;;
        --questions) QUESTIONS="$2"; shift 2 ;;
        --k) K="$2"; shift 2 ;;
        --help | -h)
            echo "usage: measure-recall-at-k.sh --index-dir <dir> --questions <tsv: band<TAB>question> [--k N]"
            exit 0
            ;;
        *) echo "error: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$INDEX_DIR" ] || { echo "error: --index-dir required" >&2; exit 2; }
[ -n "$QUESTIONS" ] || { echo "error: --questions required" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/recall-at-k.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

_unload_all() {
    local m
    for m in $(curl -sS "$ENDPOINT/api/ps" 2>/dev/null | jq -r '.models[]?.name' | tr -d ''); do
        curl -sS -o /dev/null -X POST "$ENDPOINT/api/generate" \
            -d "$(jq -nc --arg m "$m" '{model:$m, keep_alive:0, prompt:""}')" 2>/dev/null
    done
    sleep 3
}

# ── PHASE 1: retrieve, embedder only ────────────────────────────────────────
_unload_all
: > "$TMP/retrieved.jsonl"
while IFS=$'\t' read -r band question; do
    [ -n "$question" ] || continue
    curl -sS --max-time 120 -X POST "$ENDPOINT/v1/embeddings" \
        -H 'content-type: application/json' \
        -d "$(jq -nc --arg m "$EMBED_MODEL" --arg i "$question" '{model:$m,input:$i}')" 2>/dev/null \
        | jq -c '.data[0].embedding' > "$TMP/qv.json"
    [ -s "$TMP/qv.json" ] && [ "$(cat "$TMP/qv.json")" != null ] || continue
    "$PLAN" spec-retrieve --index-dir "$INDEX_DIR" --query-vec "$TMP/qv.json" --k "$K" \
        2>/dev/null > "$TMP/hits.json" || continue
    jq -c --arg b "$band" --arg q "$question" \
        '{band:$b, q:$q, hits:[.[] | {path, text: (.text[0:1200]), score}]}' \
        "$TMP/hits.json" >> "$TMP/retrieved.jsonl"
done < "$QUESTIONS"
printf 'phase1: retrieved top-%s for %s questions with %s\n' \
    "$K" "$(wc -l < "$TMP/retrieved.jsonl" | tr -d ' ')" "$EMBED_MODEL" >&2

# ── PHASE 2: judge, generative model only ───────────────────────────────────
_unload_all

_ask() { # _ask <prompt> -> YES|NO|EMPTY|UNPARSED
    local r raw
    r="$(curl -sS --max-time 180 -X POST "$ENDPOINT/api/generate" \
        -H 'content-type: application/json' \
        -d "$(jq -nc --arg m "$JUDGE_MODEL" --arg p "$1" \
            '{model:$m,prompt:$p,stream:false,options:{temperature:0,num_predict:4}}')" 2>/dev/null)"
    raw="$(printf '%s' "$r" | jq -r '.response // ""' | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
    case "$raw" in
        YES*) printf 'YES' ;; NO*) printf 'NO' ;; "") printf 'EMPTY' ;; *) printf 'UNPARSED' ;;
    esac
}

printf 'band\thit_rank\tverdict\tpair\tpath\tquestion\n'
while IFS= read -r row; do
    band="$(jq -r '.band' <<<"$row")"
    q="$(jq -r '.q' <<<"$row")"
    n="$(jq -r '.hits | length' <<<"$row")"
    i=0
    while [ "$i" -lt "$n" ]; do
        path="$(jq -r --argjson i "$i" '.hits[$i].path' <<<"$row")"
        text="$(jq -r --argjson i "$i" '.hits[$i].text' <<<"$row")"
        aff="$(_ask "QUESTION: ${q}

PASSAGE:
${text}

Does the passage contain information that answers the question? Reply YES or NO.")"
        neg="$(_ask "QUESTION: ${q}

PASSAGE:
${text}

Is the passage MISSING the information needed to answer the question? Reply YES or NO.")"
        case "${aff}/${neg}" in
            YES/NO) v=SUPPORTED ;;
            NO/YES) v=UNSUPPORTED ;;
            YES/YES | NO/NO) v=CONTRADICTION ;;
            *EMPTY*) v=JUDGE-EMPTY ;;
            *) v=JUDGE-UNPARSED ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$band" "$((i + 1))" "$v" "${aff}/${neg}" "$path" "$q"
        # An answered question needs no further ranks; a refused one does.
        [ "$v" = SUPPORTED ] && break
        i=$((i + 1))
    done
done < "$TMP/retrieved.jsonl"
