#!/usr/bin/env bash
# bench-inference-floor.sh — measure a host's local-inference floor
# @trace spec:inference-container
# order 402 / 410 / 481 / 482 — engine-lane measurement; 552 — re-embed budget
#
# WHY THIS EXISTS: the project had NO benchmark harness. Every engine-lane
# decision in images/inference/engine-tuning.sh cites a hand-run A/B typed into
# a comment, and every lane except CUDA is marked "unmeasured" for exactly that
# reason. A lane may not be tuned from an asserted number, so the number needs a
# reproducible producer.
#
# MEASUREMENT STYLE matches the CUDA A/B already recorded in engine-tuning.sh:
# ollama's OWN reported timings, fixed-length generations, WARM runs only.
# Generation tok/s = eval_count / eval_duration; prefill tok/s =
# prompt_eval_count / prompt_eval_duration. We never wall-clock the whole
# request and call it throughput — that folds load and queue time into the rate.
#
# THE ENGINE LABEL IS DERIVED, NEVER TRUSTED. Whether a model actually ran on an
# accelerator is read back from /api/ps (size_vram vs size) AFTER the model is
# resident. An operator-supplied label is reported separately as `claimed=` so a
# mislabelled run is visible instead of silently becoming evidence. This is the
# order-392 boundary rule: a GPU tier in name only is worse than no GPU tier.
#
# PINNED GRAMMAR — one line per model, plus one embed: and one project: line:
#   host: name=<n> cores=<N> ram_gb=<N> mem=<desc> bw_ceiling_gb_s=<F>
#   gen: model=<n> tier=<T> engine=<e> claimed=<e> offload_pct=<N> load_ms=<N> \
#        prefill_tok_s=<F> gen_tok_s=<F> prompt_tok=<N> eval_tok=<N> total_ms=<N>
#   embed: model=<n> engine=<e> n=<N> total_ms=<N> per_chunk_ms=<F> chunks_per_s=<F>
#   project: full_rebuild_chunks=<N> full_rebuild_s=<F> delta_10_chunks_s=<F> \
#        delta_40_chunks_s=<F>
#
# Dependencies: curl, jq. No python (forbidden for committed automation).
#
# Usage:
#   scripts/bench-inference-floor.sh
#   BENCH_ENDPOINT=http://127.0.0.1:11435 BENCH_ENGINE_LABEL=cpu-wsl2 \
#     scripts/bench-inference-floor.sh

set -uo pipefail

EP="${BENCH_ENDPOINT:-${TILLANDSIAS_INFERENCE_ENDPOINT:-http://127.0.0.1:11434}}"
CLAIMED="${BENCH_ENGINE_LABEL:-unspecified}"
NUM_PREDICT="${BENCH_NUM_PREDICT:-200}"
EMBED_MODEL="${TILLANDSIAS_EMBED_MODEL:-nomic-embed-text}"
EMBED_N="${BENCH_EMBED_N:-10}"
HOST_NAME="${BENCH_HOST_NAME:-$(hostname 2>/dev/null || echo unknown)}"

# Corpus constants measured on origin/windows-next 2026-08-16:
# openspec/specs + cheatsheets + methodology = 464 files, 3,262,450 bytes,
# ~816k tokens, ~1592 chunks at 512 tokens. Used only to PROJECT re-embed cost.
CORPUS_CHUNKS="${BENCH_CORPUS_CHUNKS:-1592}"

for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "bench: ERROR missing dependency: $tool" >&2
        exit 2
    }
done

if ! curl -fsS -m 5 "$EP/api/version" >/dev/null 2>&1; then
    echo "bench: ERROR no inference endpoint at $EP" >&2
    exit 2
fi

# A fixed, non-trivial prompt so prefill is measurable rather than rounding error.
PROMPT="You are a build engineer. Explain, in careful detail, why a language model's token generation speed on a small CPU is limited by memory bandwidth rather than by arithmetic throughput, and what that implies for choosing a model size on a machine with a single memory channel."

# Read back where the model ACTUALLY resides. Returns "<engine> <offload_pct>".
derive_engine() {
    local model="$1" ps size vram pct
    ps=$(curl -fsS -m 10 "$EP/api/ps" 2>/dev/null) || { echo "unknown 0"; return; }
    size=$(echo "$ps" | jq -r --arg m "$model" '.models[]? | select(.name==$m or (.name|startswith($m))) | .size' | head -1)
    vram=$(echo "$ps" | jq -r --arg m "$model" '.models[]? | select(.name==$m or (.name|startswith($m))) | .size_vram' | head -1)
    case "${size:-}" in ''|null|*[!0-9]*) echo "unknown 0"; return ;; esac
    case "${vram:-}" in ''|null|*[!0-9]*) vram=0 ;; esac
    pct=$(awk -v v="$vram" -v s="$size" 'BEGIN{ if (s>0) printf "%d", (v*100)/s; else print 0 }')
    if [ "$pct" -ge 50 ]; then echo "accelerated $pct"; else echo "cpu $pct"; fi
}

bench_model() {
    local model="$1" tier="$2" resp engine_pair engine pct

    # WARM-UP: load weights, compile kernels/shaders, fill caches. Discarded.
    # A Vulkan/Metal lane compiles pipelines on first use; measuring that as
    # prefill produces a number that looks like a regression and is not one.
    curl -fsS -m 900 "$EP/api/generate" \
        -d "$(jq -nc --arg m "$model" --arg p "$PROMPT" \
              '{model:$m, prompt:$p, stream:false, options:{num_predict:16}}')" \
        >/dev/null 2>&1

    engine_pair=$(derive_engine "$model")
    engine=$(echo "$engine_pair" | cut -d' ' -f1)
    pct=$(echo "$engine_pair" | cut -d' ' -f2)

    resp=$(curl -fsS -m 900 "$EP/api/generate" \
        -d "$(jq -nc --arg m "$model" --arg p "$PROMPT" --argjson n "$NUM_PREDICT" \
              '{model:$m, prompt:$p, stream:false, options:{num_predict:$n}}')" 2>/dev/null)

    if [ -z "$resp" ]; then
        echo "gen: model=$model tier=$tier engine=$engine claimed=$CLAIMED ERROR=no-response"
        return
    fi

    echo "$resp" | jq -r \
        --arg m "$model" --arg t "$tier" --arg e "$engine" \
        --arg c "$CLAIMED" --arg p "$pct" '
        def div($a; $b): if ($b // 0) > 0 then ($a / $b) else 0 end;
        def r2: (. * 100 | floor) / 100;
        "gen: model=\($m) tier=\($t) engine=\($e) claimed=\($c) offload_pct=\($p)"
        + " load_ms=\(((.load_duration // 0) / 1000000) | floor)"
        + " prefill_tok_s=\(div(.prompt_eval_count // 0; (.prompt_eval_duration // 0) / 1000000000) | r2)"
        + " gen_tok_s=\(div(.eval_count // 0; (.eval_duration // 0) / 1000000000) | r2)"
        + " prompt_tok=\(.prompt_eval_count // 0) eval_tok=\(.eval_count // 0)"
        + " total_ms=\(((.total_duration // 0) / 1000000) | floor)"
    '
}

bench_embed() {
    local chunk payload start end i total_ms per_ms cps engine_pair engine

    # Real prose, not random bytes. A base64/urandom chunk tokenizes near
    # worst-case and inflates per-chunk cost several-fold — an early draft of
    # this harness reported 8977 ms/chunk that way against a true ~2900 ms.
    if [ -r methodology/philosophy.yaml ]; then
        chunk=$(head -c 2000 methodology/philosophy.yaml)
    else
        chunk=$(printf 'the quick brown fox jumps over the lazy dog. %.0s' $(seq 1 45))
    fi

    payload=$(jq -nc --arg m "$EMBED_MODEL" --arg c "$chunk" '{model:$m, input:$c}')

    # Warm-up (loads the embedding model).
    printf '%s' "$payload" | curl -fsS -m 300 "$EP/api/embed" -d @- >/dev/null 2>&1

    engine_pair=$(derive_engine "$EMBED_MODEL")
    engine=$(echo "$engine_pair" | cut -d' ' -f1)

    # Sequential, one round trip per chunk — the shape a commit-time re-embed
    # would use. Batching was measured at only ~14% better (order 552 evidence),
    # so the sequential number is not a strawman.
    start=$(date +%s%N)
    i=0
    while [ "$i" -lt "$EMBED_N" ]; do
        printf '%s' "$payload" | curl -fsS -m 300 "$EP/api/embed" -d @- >/dev/null 2>&1
        i=$((i + 1))
    done
    end=$(date +%s%N)

    total_ms=$(( (end - start) / 1000000 ))
    per_ms=$(awk -v t="$total_ms" -v n="$EMBED_N" 'BEGIN{printf "%.1f", t/n}')
    cps=$(awk -v t="$total_ms" -v n="$EMBED_N" 'BEGIN{ if (t>0) printf "%.2f", n*1000/t; else print 0 }')

    echo "embed: model=$EMBED_MODEL engine=$engine claimed=$CLAIMED n=$EMBED_N total_ms=$total_ms per_chunk_ms=$per_ms chunks_per_s=$cps"

    awk -v p="$per_ms" -v c="$CORPUS_CHUNKS" 'BEGIN{
        printf "project: full_rebuild_chunks=%d full_rebuild_s=%.1f", c, c*p/1000
        printf " delta_10_chunks_s=%.2f delta_40_chunks_s=%.2f\n", 10*p/1000, 40*p/1000
    }'
}

cores=$(nproc 2>/dev/null || echo unknown)
echo "host: name=$HOST_NAME cores=$cores endpoint=$EP claimed_engine=$CLAIMED num_predict=$NUM_PREDICT"

bench_model "qwen2.5:0.5b"   "T0"
bench_model "tinyllama:1.1b" "T1"
bench_model "phi3.5:3.8b"    "T2"
bench_embed
