#!/usr/bin/env bash
# bench-semantic-budget.sh — can a model meet semantic_expert's latency budget?
# @trace spec:inference-container
# order 393 (deterministic engine vs model), 391 (forge-local-experts-milestone)
#
# WHY SEPARATE FROM bench-inference-floor.sh: that harness measures ENGINE
# throughput (tok/s per lane). This one answers a different question — whether a
# given model can complete the semantic_expert round trip inside its socket
# timeout. Throughput does not answer it, because the budget is wall clock on a
# COMPLETE response and a large share of that is neither prefill nor generation.
#
# FAITHFUL to crates/tillandsias-plan/src/semantic_expert.rs:
#   - exact prompt shape (:357)
#   - stream:false; num_predict UNSET by default because the code sets none (:305)
#   - the budget is a SOCKET READ TIMEOUT (:250, :303), so the whole response
#     must arrive inside it
#   - on timeout the caller falls back to the raw section text (:369), so failure
#     is SILENT DEGRADATION, not an error
#
# A PASS EARNED BY NOT ANSWERING IS A BUG, NOT A RESULT. Measured 2026-08-16:
# gemma3:270m "met" a 1500ms budget by emitting ONE token, and smollm2:135m met
# it with 42 tokens of hallucination. A verdict that ignores answer length
# rewards a model for staying silent, so eval_tok is part of the pinned grammar
# and a short answer is reported as PASS-DEGENERATE, never PASS.
#
# PINNED GRAMMAR — one line per model:
#   semantic: model=<n> verdict=<PASS|PASS-DEGENERATE|FAIL|ERROR> avg_ms=<N> \
#     best_ms=<N> worst_ms=<N> budget_ms=<N> prompt_tok=<N> eval_tok=<N> \
#     prefill_ms=<N> gen_ms=<N>
#
# Dependencies: curl, jq, GNU date. No python (forbidden for committed automation).
#
# Usage:
#   scripts/bench-semantic-budget.sh
#   BENCH_MODELS="smollm2:135m qwen2.5:0.5b" BENCH_NUM_PREDICT=64 \
#     scripts/bench-semantic-budget.sh

set -uo pipefail

EP="${BENCH_ENDPOINT:-${TILLANDSIAS_INFERENCE_ENDPOINT:-http://127.0.0.1:11434}}"
BUDGET_MS="${BENCH_BUDGET_MS:-1500}"
REPS="${BENCH_REPS:-3}"
# Empty = faithful to the code (no cap). Set to bound generation experimentally.
NUM_PREDICT="${BENCH_NUM_PREDICT:-}"
# Below this, an answer is not an answer — see the header.
MIN_TOK="${BENCH_MIN_EVAL_TOK:-16}"
MODELS="${BENCH_MODELS:-smollm2:135m gemma3:270m smollm2:360m qwen2.5:0.5b qwen3:0.6b tinyllama:1.1b}"

for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "bench: ERROR missing dependency: $tool" >&2; exit 2; }
done
curl -fsS -m 5 "$EP/api/version" >/dev/null 2>&1 || { echo "bench: ERROR no endpoint at $EP" >&2; exit 2; }

# GNU date guard: BSD date passes %N through literally and exits 0 with garbage,
# which an exit-code check cannot catch (766-tdij).
_now_ns() { date +%s%N; }  # gnu-date: ok (digit-validated by the refusal below)
case "$(_now_ns)" in
    '' | *[!0-9]*) echo "bench: ERROR needs GNU date (%N); this date emits garbage" >&2; exit 2 ;;
esac

# A REAL plan section — this is the shape find_section() returns. Falling back to
# methodology keeps the harness usable in a checkout without a folded ledger.
SECTION_TITLE="Direction — what are we all doing today"
SECTION_CONTENT="$(sed -n '6731,6760p' plan/loop_status.md 2>/dev/null)"
[ -n "$SECTION_CONTENT" ] || {
    SECTION_TITLE="philosophy"
    SECTION_CONTENT="$(head -c 1500 methodology/philosophy.yaml 2>/dev/null)"
}
[ -n "$SECTION_CONTENT" ] || { echo "bench: ERROR no corpus section available" >&2; exit 2; }
QUESTION="${BENCH_QUESTION:-what are we all doing today?}"

PROMPT="$(printf "Based on this excerpt from '%s':\n\n%s\n\nQuestion: %s\nAnswer concisely:" \
    "$SECTION_TITLE" "$SECTION_CONTENT" "$QUESTION")"

if [ -n "$NUM_PREDICT" ]; then
    mk_payload() { jq -nc --arg m "$1" --arg p "$PROMPT" --argjson n "$NUM_PREDICT" \
        '{model:$m, prompt:$p, stream:false, options:{num_predict:$n}}'; }
else
    mk_payload() { jq -nc --arg m "$1" --arg p "$PROMPT" \
        '{model:$m, prompt:$p, stream:false}'; }
fi

echo "budget: ${BUDGET_MS}ms endpoint=$EP reps=$REPS num_predict=${NUM_PREDICT:-unset} min_eval_tok=$MIN_TOK"
echo "section: title='$SECTION_TITLE' section_chars=${#SECTION_CONTENT} prompt_chars=${#PROMPT}"

for model in $MODELS; do
    payload="$(mk_payload "$model")"

    # Warm-up: load weights, compile kernels, prime caches. Discarded.
    if ! printf '%s' "$payload" | curl -fsS -m 600 "$EP/api/generate" -d @- >/dev/null 2>&1; then # sigpipe-ok: consumer does not exit early
        echo "semantic: model=$model verdict=ERROR reason=unavailable"
        continue
    fi

    best=""; worst=""; sum=0; n=0; prompt_tok=0; eval_tok=0; prefill_ms=0; gen_ms=0
    i=0
    while [ "$i" -lt "$REPS" ]; do
        i=$((i + 1))
        s=$(_now_ns)
        resp=$(printf '%s' "$payload" | curl -fsS -m 600 "$EP/api/generate" -d @- 2>/dev/null)
        e=$(_now_ns)
        [ -n "$resp" ] || continue
        ms=$(( (e - s) / 1000000 ))
        sum=$((sum + ms)); n=$((n + 1))
        # Explicit rather than `[ -z "$best" ] || [ ... ] && best=$ms`: that
        # idiom happens to work by left-to-right precedence, which is exactly
        # the kind of thing a later edit breaks silently.
        if [ -z "$best" ] || [ "$ms" -lt "$best" ]; then best=$ms; fi
        if [ -z "$worst" ] || [ "$ms" -gt "$worst" ]; then worst=$ms; fi
        prompt_tok=$(echo "$resp" | jq -r '.prompt_eval_count // 0')
        eval_tok=$(echo "$resp" | jq -r '.eval_count // 0')
        prefill_ms=$(echo "$resp" | jq -r '((.prompt_eval_duration // 0) / 1000000) | floor')
        gen_ms=$(echo "$resp" | jq -r '((.eval_duration // 0) / 1000000) | floor')
    done

    if [ "$n" -eq 0 ]; then
        echo "semantic: model=$model verdict=ERROR reason=no-response"
        continue
    fi

    avg=$(( sum / n ))
    if [ "$avg" -ge "$BUDGET_MS" ]; then
        verdict=FAIL
    elif [ "$eval_tok" -lt "$MIN_TOK" ]; then
        # Fast because it said nothing. Never report this as a pass.
        verdict=PASS-DEGENERATE
    else
        verdict=PASS
    fi

    echo "semantic: model=$model verdict=$verdict avg_ms=$avg best_ms=$best worst_ms=$worst budget_ms=$BUDGET_MS prompt_tok=$prompt_tok eval_tok=$eval_tok prefill_ms=$prefill_ms gen_ms=$gen_ms"
done
