#!/usr/bin/env bash
# judge-support.sh — Tier B of the expert layer: does the retrieved span
# actually SUPPORT the question, as judged by a local model?
#
# WHY THIS EXISTS. A cosine score cannot decide refusal: at n=579 the in-corpus
# and out-of-corpus bands overlap by 0.30 globally and by 0.17-0.28 in every
# single corpus. The score conflates "topically near" with "actually answers",
# which are different properties flattened onto one axis.
#
# This asks the other question instead, about CONTENT rather than geometry:
# given the question and the text that was retrieved for it, does that text
# answer it? Checking a passage is a strictly easier task than finding one, and
# that asymmetry is what makes a small local model a plausible judge.
#
# THE POINT OF THE EXERCISE is the model SIZE. If a 0.5B model can do this, the
# expert layer runs on the fleet's Intel laptops, not just the A5000 — which is
# the whole argument for doing numerical methods locally on commodity hardware.
#
# Reads the TSV that measure-bands.sh emits (band/corpus/top1/.../path/question)
# and re-reads the chunk text from the index by path, so the judgement is made
# against what the retriever ACTUALLY returned rather than a paraphrase.
set -uo pipefail

MODEL="${TILLANDSIAS_JUDGE_MODEL:-qwen2.5:0.5b}"
ENDPOINT="${TILLANDSIAS_INFERENCE_ENDPOINT:-http://127.0.0.1:11434}"
INDEX_DIR=""
TSV=""

while [ $# -gt 0 ]; do
    case "$1" in
        --model) MODEL="$2"; shift 2 ;;
        --index-dir) INDEX_DIR="$2"; shift 2 ;;
        --results) TSV="$2"; shift 2 ;;
        --help | -h)
            echo "usage: judge-support.sh --index-dir <dir> --results <tsv> [--model M]"
            echo "Reads a measure-bands TSV; emits band/verdict/question per line."
            exit 0
            ;;
        *) echo "error: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$INDEX_DIR" ] || { echo "error: --index-dir required" >&2; exit 2; }
[ -n "$TSV" ] || { echo "error: --results required" >&2; exit 2; }

printf 'band\tverdict\tpair\ttop1\tquestion\n'

while IFS=$'\t' read -r band corpus top1 top2 margin kind path question; do
    [ -n "$question" ] || continue

    # The exact text the retriever returned, by path. First matching chunk:
    # good enough for a support judgement, and it keeps the judge honest by
    # never showing it text the retriever did not actually surface.
    snippet="$(jq -r --arg p "$path" 'select(.path == $p) | .text' \
        "$INDEX_DIR/chunks.jsonl" 2>/dev/null | head -c 1200)"
    [ -n "$snippet" ] || snippet="(no text found for $path)"

    # KEEP THIS PROMPT NEUTRAL. The first version of it said "Answering NO is
    # expected and correct ... Do not be generous", and qwen2.5:0.5b then
    # answered UNSUPPORTED to all 70 questions — 40 in-corpus included. Scored
    # against the out-of-corpus band alone that reads as 30/30 perfect
    # refusals; the in-corpus control is the only thing that exposes it as a
    # judge that always says no. A judge instructed toward an answer will
    # converge on it no matter how many waves are run, which is exactly the
    # bias-not-variance failure that breaks the law-of-large-numbers argument.
    read -r -d '' prompt <<EOF
QUESTION: ${question}

PASSAGE:
${snippet}

Does the passage contain information that answers the question? Reply YES or NO.
EOF

    # THE COMPLEMENT. Operator design: ask the affirmative AND its negation. A
    # judge that answers the same way to both is following the SHAPE of the
    # prompt rather than reading the passage, and that contradiction is
    # detectable with NO ground truth and no labelled set — which is what makes
    # it usable at runtime rather than only in a lab. Demonstrated on
    # qwen2.5:0.5b 2026-08-22: YES to both "does it answer" and "is the answer
    # missing", on a passage that answers AND on one that does not.
    read -r -d '' comp <<EOF
QUESTION: ${question}

PASSAGE:
${snippet}

Is the passage MISSING the information needed to answer the question? Reply YES or NO.
EOF

    _ask() { # _ask <prompt> -> YES|NO|EMPTY|UNPARSED
        local b r raw
        b="$(jq -nc --arg m "$MODEL" --arg p "$1" \
            '{model:$m, prompt:$p, stream:false, options:{temperature:0, num_predict:4}}')"
        r="$(curl -sS --max-time 180 -X POST "$ENDPOINT/api/generate" \
            -H 'content-type: application/json' -d "$b" 2>/dev/null)"
        raw="$(printf '%s' "$r" | jq -r '.response // ""' | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
        case "$raw" in
            YES*) printf 'YES' ;;
            NO*) printf 'NO' ;;
            "") printf 'EMPTY' ;;
            *) printf 'UNPARSED' ;;
        esac
    }

    aff="$(_ask "$prompt")"
    neg="$(_ask "$comp")"

    # An unparseable answer is its OWN verdict, never silently a NO. A judge
    # that fails to answer must not be counted as having refused correctly —
    # that would score a broken judge as a strict one.
    #
    # CONTRADICTION outranks both. "Answers it" and "is missing the answer"
    # cannot both be true; agreement between them is the only reading either
    # one earns.
    case "${aff}/${neg}" in
        YES/NO) verdict=SUPPORTED ;;
        NO/YES) verdict=UNSUPPORTED ;;
        YES/YES | NO/NO) verdict=CONTRADICTION ;;
        *EMPTY*) verdict=JUDGE-EMPTY ;;
        *) verdict=JUDGE-UNPARSED ;;
    esac

    printf '%s\t%s\t%s\t%s\t%s\n' "$band" "$verdict" "${aff}/${neg}" "$top1" "$question"
done <"$TSV"
