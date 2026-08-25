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
#   host: name=<n> cores=<N> ram_gb=<N> mem=<desc> bw_ceiling_gb_s=<F> \
#        dispatch=<ok:engine-cpu-dispatch:<f,..>|refused:...|unchecked:no-engine-binary>
#   gen: model=<n> tier=<T> engine=<e> claimed=<e> offload_pct=<N> load_ms=<N> \
#        prefill_tok_s=<F> prefill_n=<N> prefill_range=<F>-<F> prefill_prompt_tok=<N> \
#        gen_tok_s=<F> prompt_tok=<N> eval_tok=<N> total_ms=<N>
#   embed: model=<n> engine=<e> n=<N> chars=<N> total_ms=<N> per_chunk_ms=<F> \
#        chunks_per_s=<F>
#   project: chunk_chars=<N> (full_rebuild_chunks=<N> full_rebuild_s=<F> |
#        full_rebuild=skipped:no-measured-corpus-chunk-count) \
#        delta_10_chunks_s=<F> delta_40_chunks_s=<F>
#
# GRAMMAR CHANGED 2026-08-23 (order 858-ihcb). `prefill_tok_s` is now the MEDIAN
# of BENCH_PREFILL_REPS isolated measurements rather than a single cached one,
# and `prefill_n`/`prefill_range` report the sample so a reader can see the
# spread instead of trusting a point estimate. `embed:` gained `chars=` and
# `project:` gained `chunk_chars=` because per_chunk_ms is meaningless without
# the chunk size. Nothing machine-parses these lines today (no litmus pins
# them; the only in-tree reference is this file's own docstring), so the
# addition is safe — but EVERY prefill_tok_s recorded before this date was
# measured against a warm prompt cache and is superseded, not comparable.
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
# NO DEFAULT, deliberately (order 858-ihcb). This was `${BENCH_CORPUS_CHUNKS:-1592}`
# — an estimate ("816k tokens / 512") that the 2026-08-17 real-chunker
# measurement replaced with 9,909 chunks at a p50 of 236 chars. It was then
# multiplied by the cost of a 2000-char chunk, so the projection was wrong
# twice: 6.2x too few chunks times 5.6x too much per chunk. On esmeraldinha it
# printed full_rebuild_s=3918.5 (65 min) against a true ~72 min — close, and
# close BY CANCELLATION, which stops being close the moment either input is
# corrected on its own. A projection nobody can attribute is worse than none,
# so with no measured count supplied this harness now declines to project.
CORPUS_CHUNKS="${BENCH_CORPUS_CHUNKS:-}"

# The embed chunk size is now REPORTED rather than implied. The old harness
# sent 2000 chars while the corpus p50 is ~236, and nothing in its output said
# so — which is precisely how a per_chunk_ms got compared against numbers taken
# at a different size. Default to the measured p50; override for a sweep.
EMBED_CHUNK_CHARS="${BENCH_EMBED_CHUNK_CHARS:-250}"

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

# Nanosecond clock. BSD date does NOT understand %N and passes it through
# literally, so `date +%s%N` exits 0 with "1755387123N" — a successful command
# emitting garbage, which an exit-code guard cannot catch and which would
# silently become a plausible-looking per_chunk_ms. Validate the digits once,
# up front, and refuse rather than publish a timing number derived from an
# unverified clock (766-tdij). A benchmark that lies is worse than no benchmark.
_bench_now_ns() { date +%s%N; }  # gnu-date: ok (digit-validated by the refusal below)
case "$(_bench_now_ns)" in
    '' | *[!0-9]*)
        echo "bench: ERROR this date(1) does not support %N nanoseconds (BSD date emits garbage)." >&2
        echo "bench: install GNU coreutils date, or run this harness on a GNU host." >&2
        exit 2
        ;;
esac

# A fixed, non-trivial prompt so prefill is measurable rather than rounding error.
PROMPT="You are a build engineer. Explain, in careful detail, why a language model's token generation speed on a small CPU is limited by memory bandwidth rather than by arithmetic throughput, and what that implies for choosing a model size on a machine with a single memory channel."

# ── Prompt-cache defeat (order 858-ihcb) ─────────────────────────────────────
#
# THE DEFECT THIS REPLACES. bench_model() warmed up with the IDENTICAL prompt
# and then measured that same prompt. The warm-up's OUTPUT was discarded, as its
# comment said; the KV CACHE it filled was not. So `prompt_eval_duration` on the
# measured call covered a cache hit and `prefill_tok_s` was inflated by an
# unknown factor. Measured on esmeraldinha 2026-08-23, qwen2.5:0.5b, one server:
#
#   identical prompt repeated (what this file used to do)   934.4 / 1008.4 tok/s
#   same prompt with a UNIQUE SUFFIX appended               365.8 / 474.3 / 394.1
#   full 793-zumy controls, same model/lane/machine                    88.3 tok/s
#
# The middle row is the instructive one: appending a unique suffix does NOT
# defeat the cache, because ollama reuses a matching PREFIX and only the novel
# tail is evaluated — while `prompt_eval_count` still reports the whole prompt.
# So the unique token must come FIRST. That is what 793-zumy's method specified
# and what this harness did not adopt; every prefill_tok_s it emitted, on every
# host, is superseded.
#
# Two controls are needed and they pull in OPPOSITE directions: a reused prompt
# makes the lane look impossibly fast, and a cold first dispatch (Vulkan/dzn/
# Metal pipeline compilation) makes it look exactly like the CPU. So: unique
# prompt per repetition, unique token first, AND discard the first post-load
# repetition.
BENCH_PREFILL_REPS="${BENCH_PREFILL_REPS:-3}"
_bench_run_id="$(_bench_now_ns)"

# A prompt no cache has seen, distinguished in its FIRST tokens.
#
# THE TAG IS AN ARGUMENT, NOT AN INTERNAL COUNTER, and that is load-bearing.
# The first version of this incremented a `_bench_nonce` global — but every
# call site invokes it inside `$( ... )`, which runs in a SUBSHELL, so the
# increment never reached the parent and every "unique" prompt was byte
# identical. It reported prefill_tok_s=1528 (range 1512-2195) on esmeraldinha,
# i.e. it reproduced the very cached-prefill defect it was written to remove,
# while looking like it had fixed it. Caught by a three-arm control: identical
# prompts 1338-1448 tok/s, nonce-prefixed 93-148, fully distinct 125-140.
# The caller owns uniqueness; this function only places it FIRST.
unique_prompt() {
    printf 'Case %s-%s. %s' "$1" "$_bench_run_id" "$PROMPT"
}

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

# Isolated prefill: `num_predict:1` so decode contributes essentially nothing,
# a unique prompt per repetition, and the first post-load repetition discarded.
# Prints "<median_tok_s> <prompt_tok> <kept_n> <min>-<max>", or "" on failure.
bench_prefill() {
    local model="$1" i resp v ptok="0" vals="" kept=0
    for i in $(seq 1 $((BENCH_PREFILL_REPS + 1))); do
        resp=$(curl -fsS -m 900 "$EP/api/generate" \
            -d "$(jq -nc --arg m "$model" --arg p "$(unique_prompt "pf$i-$model")" \
                  '{model:$m, prompt:$p, stream:false, options:{num_predict:1}}')" 2>/dev/null)
        [ -n "$resp" ] || continue
        # Discard the cold dispatch: the first prefill after a model load pays
        # pipeline compilation on an accelerated lane and reads at roughly CPU
        # speed (793-zumy measured 86.00 then 189.03 then a 0.8 tok/s band).
        [ "$i" -eq 1 ] && continue
        v=$(printf '%s' "$resp" | jq -r '
            if ((.prompt_eval_duration // 0) > 0)
            then ((.prompt_eval_count // 0) / ((.prompt_eval_duration) / 1000000000))
            else empty end')
        [ -n "$v" ] || continue
        ptok=$(printf '%s' "$resp" | jq -r '.prompt_eval_count // 0')
        vals="$vals$v
"
        kept=$((kept + 1))
    done
    [ "$kept" -gt 0 ] || return 1
    # Median, not mean: one scheduler hiccup on a 4-core box skews a mean and
    # this harness exists to be trusted on exactly such boxes.
    printf '%s' "$vals" | sort -g | awk -v n="$kept" -v pt="$ptok" '
        {a[NR]=$1}
        END{
            m = (NR % 2) ? a[(NR+1)/2] : (a[NR/2] + a[NR/2+1]) / 2;
            printf "%.2f %s %d %.2f-%.2f", m, pt, n, a[1], a[NR];
        }'
}

bench_model() {
    local model="$1" tier="$2" resp engine_pair engine pct pf pf_tok_s pf_ptok pf_n pf_range

    # WARM-UP: load weights, compile kernels/shaders. Discarded. Its prompt is
    # unique too — a warm-up that seeds the cache with the prompt we are about
    # to measure IS the 858-ihcb defect.
    curl -fsS -m 900 "$EP/api/generate" \
        -d "$(jq -nc --arg m "$model" --arg p "$(unique_prompt "warm-$model")" \
              '{model:$m, prompt:$p, stream:false, options:{num_predict:16}}')" \
        >/dev/null 2>&1

    engine_pair=$(derive_engine "$model")
    engine=$(echo "$engine_pair" | cut -d' ' -f1)
    pct=$(echo "$engine_pair" | cut -d' ' -f2)

    pf="$(bench_prefill "$model")" || pf=""
    pf_tok_s="${pf%% *}";      pf="${pf#* }"
    pf_ptok="${pf%% *}";       pf="${pf#* }"
    pf_n="${pf%% *}"
    pf_range="${pf#* }"
    [ -n "$pf_tok_s" ] || { pf_tok_s=0; pf_ptok=0; pf_n=0; pf_range="0-0"; }

    # Decode, measured separately and with its own unique prompt. Decode is NOT
    # affected by the prompt cache (eval_duration covers generation only), which
    # is why the four decode figures this harness produced on esmeraldinha agreed
    # with the controlled 793-zumy run to 3% while prefill was 15x out.
    resp=$(curl -fsS -m 900 "$EP/api/generate" \
        -d "$(jq -nc --arg m "$model" --arg p "$(unique_prompt "gen-$model")" --argjson n "$NUM_PREDICT" \
              '{model:$m, prompt:$p, stream:false, options:{num_predict:$n}}')" 2>/dev/null)

    if [ -z "$resp" ]; then
        echo "gen: model=$model tier=$tier engine=$engine claimed=$CLAIMED ERROR=no-response"
        return
    fi

    echo "$resp" | jq -r \
        --arg m "$model" --arg t "$tier" --arg e "$engine" \
        --arg c "$CLAIMED" --arg p "$pct" \
        --arg pf "$pf_tok_s" --arg pft "$pf_ptok" --arg pfn "$pf_n" --arg pfr "$pf_range" '
        def div($a; $b): if ($b // 0) > 0 then ($a / $b) else 0 end;
        def r2: (. * 100 | floor) / 100;
        "gen: model=\($m) tier=\($t) engine=\($e) claimed=\($c) offload_pct=\($p)"
        + " load_ms=\(((.load_duration // 0) / 1000000) | floor)"
        + " prefill_tok_s=\($pf) prefill_n=\($pfn) prefill_range=\($pfr) prefill_prompt_tok=\($pft)"
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
        chunk=$(head -c "$EMBED_CHUNK_CHARS" methodology/philosophy.yaml)
    else
        chunk=$(printf 'the quick brown fox jumps over the lazy dog. %.0s' $(seq 1 45) \
                | head -c "$EMBED_CHUNK_CHARS")
    fi

    payload=$(jq -nc --arg m "$EMBED_MODEL" --arg c "$chunk" '{model:$m, input:$c}')

    # Warm-up (loads the embedding model).
    printf '%s' "$payload" | curl -fsS -m 300 "$EP/api/embed" -d @- >/dev/null 2>&1

    engine_pair=$(derive_engine "$EMBED_MODEL")
    engine=$(echo "$engine_pair" | cut -d' ' -f1)

    # Sequential, one round trip per chunk — the shape a commit-time re-embed
    # would use. Batching was measured at only ~14% better (order 552 evidence),
    # so the sequential number is not a strawman.
    start=$(_bench_now_ns)
    i=0
    while [ "$i" -lt "$EMBED_N" ]; do
        printf '%s' "$payload" | curl -fsS -m 300 "$EP/api/embed" -d @- >/dev/null 2>&1
        i=$((i + 1))
    done
    end=$(_bench_now_ns)

    total_ms=$(( (end - start) / 1000000 ))
    per_ms=$(awk -v t="$total_ms" -v n="$EMBED_N" 'BEGIN{printf "%.1f", t/n}')
    cps=$(awk -v t="$total_ms" -v n="$EMBED_N" 'BEGIN{ if (t>0) printf "%.2f", n*1000/t; else print 0 }')

    echo "embed: model=$EMBED_MODEL engine=$engine claimed=$CLAIMED n=$EMBED_N chars=$EMBED_CHUNK_CHARS total_ms=$total_ms per_chunk_ms=$per_ms chunks_per_s=$cps"

    # Project ONLY from a measured chunk count. The delta figures are safe to
    # emit unconditionally — they are just per_chunk_ms scaled, and carry no
    # corpus assumption — but full_rebuild needs a real count, so say plainly
    # when there isn't one instead of multiplying by a stale constant.
    if [ -n "$CORPUS_CHUNKS" ]; then
        awk -v p="$per_ms" -v c="$CORPUS_CHUNKS" -v ch="$EMBED_CHUNK_CHARS" 'BEGIN{
            printf "project: chunk_chars=%d full_rebuild_chunks=%d full_rebuild_s=%.1f", ch, c, c*p/1000
            printf " delta_10_chunks_s=%.2f delta_40_chunks_s=%.2f\n", 10*p/1000, 40*p/1000
        }'
    else
        awk -v p="$per_ms" -v ch="$EMBED_CHUNK_CHARS" 'BEGIN{
            printf "project: chunk_chars=%d full_rebuild=skipped:no-measured-corpus-chunk-count", ch
            printf " delta_10_chunks_s=%.2f delta_40_chunks_s=%.2f\n", 10*p/1000, 40*p/1000
        }'
    fi
}


# ---- ENGINE CPU DISPATCH GATE (order 861-n7f5) -----------------------------
# A build that ignores the vector features this host advertises is a
# MISCONFIGURATION, not a candidate, and its numbers are a 12.8x prefill
# regression nobody can explain. Measured on esmeraldinha 2026-08-23 against
# Fedora 44's packaged llama-cpp on a host with AVX/AVX2/FMA/AVX_VNNI.
#
# So a baseline build may still be benchmarked deliberately — what it may not
# do is enter the ledger AS AN ENGINE-LANE MEASUREMENT. When the checked engine
# is refused, this run publishes `claimed_engine=refused:<missing>` instead of
# the operator's label, so the lane label can never be the thing that carries a
# misconfigured build into evidence.
#
# The check runs only when an engine binary is named (BENCH_ENGINE_BINARY).
# The common ollama-over-HTTP path has no local binary to inspect and reports
# `dispatch=unchecked:no-engine-binary` — an honest unknown, never an `ok`.
DISPATCH="unchecked:no-engine-binary"
if [ -n "${BENCH_ENGINE_BINARY:-}" ]; then
    DISPATCH="$("$(dirname "${BASH_SOURCE[0]}")/check-engine-cpu-dispatch.sh" \
                "$BENCH_ENGINE_BINARY" 2>/dev/null)" || true
    [ -n "$DISPATCH" ] || DISPATCH="unavailable:check-did-not-run"
    case "$DISPATCH" in
        refused:*)
            echo "[bench-inference-floor] REFUSING to publish an engine lane label:" >&2
            echo "  $DISPATCH" >&2
            echo "  Re-run with a build that dispatches this host's vector features," >&2
            echo "  or read the numbers below as a build comparison, not a lane." >&2
            CLAIMED="$DISPATCH"
            ;;
    esac
fi
cores=$(nproc 2>/dev/null || echo unknown)
echo "host: name=$HOST_NAME cores=$cores endpoint=$EP claimed_engine=$CLAIMED dispatch=$DISPATCH num_predict=$NUM_PREDICT"

# Model set. Defaults to the models.json tier table; override with a
# space-separated `<model>:<label>` list to sweep a different range, e.g. the
# sub-1B decomposition sweep this host exists to characterise:
#
#   BENCH_MODELS="smollm2:135m=S135 gemma3:270m=S270 qwen2.5:0.5b=T0" \
#     scripts/bench-inference-floor.sh
#
# The label is free-form: tier names (T0..T5) for the shipped table, anything
# else for exploratory sweeps. A model absent from the endpoint reports
# ERROR=no-response and does NOT abort the sweep — one missing model must not
# cost the other measurements.
BENCH_MODELS="${BENCH_MODELS:-qwen2.5:0.5b=T0 tinyllama:1.1b=T1 phi3.5:3.8b=T2}"

for spec in $BENCH_MODELS; do
    # Split on the LAST '=' so model tags containing ':' (qwen2.5:0.5b) survive.
    model="${spec%=*}"
    label="${spec##*=}"
    [ -n "$model" ] || continue
    [ "$label" = "$spec" ] && label="-"
    bench_model "$model" "$label"
done

bench_embed
