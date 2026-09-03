#!/usr/bin/env bash
# @trace spec:accel-capability-probe
#
# bench-accel-lane.sh — run the SAME workload on one accelerator lane and print
# a machine-readable result (order 802-2536).
#
# WHY THIS EXISTS AS A SHARED SCRIPT RATHER THAN A HOST RECIPE. 802-2536's whole
# point is that a per-host benchmark with per-host methodology is three
# anecdotes. The numbers only mean anything as a matrix, so the workload, the
# warm-up, the sample and the reported statistic have to be identical on every
# host. That is a script, not a paragraph in a packet.
#
# THE METHODOLOGY IS NOT MINE — it is what the windows host arrived at the hard
# way (284513c22), and every element below exists because omitting it produced a
# wrong number that was then believed:
#
#   * REAL corpus chunks, never synthetic. A first measurement used a synthetic
#     ~2000-char chunk against a real corpus p50 of 254; it did not measure the
#     workload it was used to reason about, and its conclusion survived two
#     rounds of correction because the number was carried forward.
#   * WARM-UP, discarded. The first dispatch on a Vulkan path pays pipeline
#     compilation and reads at roughly CPU speed, so an un-warmed run flatters
#     the CPU arm.
#   * REPS, all of them reported. rep1 is routinely the cold tail; a single rep
#     is not a measurement.
#   * OFFLOAD VERIFIED PER ARM. A "gpu" arm whose server silently failed to
#     start and fell back is the failure mode that invalidated their first two
#     attempts — one run showed the GPU 14% faster with offload=0 on BOTH arms.
#     This script therefore records what the lane REPORTED, and refuses to label
#     an arm by intent alone.
#
# TWO WORKLOAD SHAPES, because that is the axis that actually decides:
#   embed    — one forward pass, no decode: prefill-shaped, batched GEMM,
#              compute-bound. The shape an iGPU tends to WIN.
#   generate — decode-shaped, memory-latency bound. The shape a CPU with wide
#              vector units tends to win on small models.
# Routing by host class instead of by workload shape is what the fleet's earlier
# per-host conclusions kept getting wrong.
#
# Output: one JSON object on stdout. Exit non-zero only on a fault that makes the
# numbers meaningless (endpoint unreachable, no chunks) — never on "the lane was
# slow".
#
# Usage:
#   scripts/bench-accel-lane.sh --lane cpu [--record] [--endpoint http://127.0.0.1:11434]
#                               [--chunks <chunks.jsonl>] [--n 40] [--reps 3]
#                               [--embed-model nomic-embed-text]
#                               [--gen-model qwen2.5:0.5b]
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LANE=""
# --force-lane: ask the SERVER for the lane rather than only labelling the run.
# Off by default so existing two-server callers (the Linux+Vulkan shape this
# script was written for) are unchanged.
FORCE_LANE=0
# --model-params-b: override the size parsed from the model tag.
MODEL_PARAMS_B=""
ENDPOINT="${TILLANDSIAS_BENCH_ENDPOINT:-http://127.0.0.1:11434}"
# Order 801-a2by moved the index out of tmpfs into the durable, content-
# addressed tier, so the old /dev/shm literal now names a path nothing writes.
# Ask the PRODUCER where it publishes rather than carrying a fourth copy of the
# resolution chain — `--where` is exactly that question and needs no endpoint.
# The tmpfs path stays as the last resort so a host with a warm legacy index,
# or one where the producer is absent, still benchmarks instead of refusing.
CHUNKS="${TILLANDSIAS_BENCH_CHUNKS:-}"
if [ -z "$CHUNKS" ]; then
    _bal_root="$(cd "$(dirname "$0")/.." && pwd)"
    _bal_dir=""
    if [ -x "$_bal_root/scripts/spec-index-ensure.sh" ]; then
        _bal_dir="$(bash "$_bal_root/scripts/spec-index-ensure.sh" --where 2>/dev/null \
            | sed -n 's/^spec-index:serving=//p')"
    fi
    if [ -n "$_bal_dir" ] && [ -s "$_bal_dir/chunks.jsonl" ]; then
        CHUNKS="$_bal_dir/chunks.jsonl"
    else
        CHUNKS="/dev/shm/tillandsias-experts/spec-index/chunks.jsonl"
    fi
fi
N=40
REPS=3
# WHERE this benchmark is running, carried into the recorded measurement
# (orders 808-43mw, 810-jeg7). An INPUT, not a derivation: the script cannot
# reliably tell "in the guest" from "on the host talking to a mirrored port"
# by inspection, and a wrong locus is worse than an absent one -- absent reads
# as unknown, wrong reads as comparable.
#
# Unset stays unset, deliberately. `MeasurementRecord.locus` is Option, so an
# unlabelled run records honestly as unlabelled rather than defaulting to a
# guess that a consumer would then rank against a labelled row.
#
# This host measured the same suite at two loci and the hop cost 5-10% on the
# embed arm -- enough to have inverted a cross-host conclusion once already.
LOCUS="${TILLANDSIAS_BENCH_LOCUS:-}"
# The suite label was ALREADY in this script's stdout JSON and was dropped on
# the way into --record-measurement, because MeasurementRecord had nowhere to
# put it (808-43mw). One constant now feeds both, so they cannot drift.
WORKLOAD_SUITE="802-2536-v1"
EMBED_MODEL="nomic-embed-text"
GEN_MODEL="qwen2.5:0.5b"
GEN_PROMPT="Summarize the purpose of a container enclave in two sentences."
GEN_TOKENS=64

while [ $# -gt 0 ]; do
    case "$1" in
        --lane) LANE="${2:-}"; shift 2 ;;
        # ORDER 793-qc6q. Make `--lane cpu` MEAN something on a host whose
        # accelerator is the default. On Linux+Vulkan the two lanes are
        # different SERVERS, so the label alone distinguished them. On macOS
        # there is one server and Metal is always on, so `--lane cpu` and
        # `--lane gpu` produced byte-identical runs, both GPU-resident — two
        # samples of one lane, reported as a comparison. That is the same
        # "labelled by intent" failure the offload check below exists to catch,
        # one level up: the ARM was mislabelled rather than the observation.
        --force-lane) FORCE_LANE=1; shift ;;
        --model-params-b) MODEL_PARAMS_B="${2:-}"; shift 2 ;;
        --record) RECORD=1; shift ;;
        --endpoint) ENDPOINT="${2:-}"; shift 2 ;;
        --chunks) CHUNKS="${2:-}"; shift 2 ;;
        --n) N="${2:-}"; shift 2 ;;
        --reps) REPS="${2:-}"; shift 2 ;;
        --embed-model) EMBED_MODEL="${2:-}"; shift 2 ;;
        --gen-model) GEN_MODEL="${2:-}"; shift 2 ;;
        *) echo "bench-accel-lane: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

[ -n "$LANE" ] || { echo "bench-accel-lane: --lane <cpu|gpu|npu> is required" >&2; exit 2; }
for t in curl jq; do
    command -v "$t" >/dev/null 2>&1 || { echo "bench-accel-lane: $t is required" >&2; exit 2; }
done
[ -s "$CHUNKS" ] || { echo "bench-accel-lane: no chunk corpus at $CHUNKS (build it with scripts/spec-index-ensure.sh)" >&2; exit 2; }
curl -fsS --max-time 10 "$ENDPOINT/api/tags" >/dev/null 2>&1 \
    || { echo "bench-accel-lane: endpoint $ENDPOINT did not answer" >&2; exit 2; }

# The per-request options that make a lane real. `num_gpu` is the number of
# layers offloaded, so 0 is a genuine CPU run on the same server — no restart,
# no second endpoint, and both arms therefore share one model cache and one
# build. Only `cpu` is forceable: there is no request-level knob that turns an
# accelerator ON where the runtime did not already choose it, so `--lane gpu
# --force-lane` deliberately sends nothing extra and still relies on the
# observation below to confirm what actually ran.
#
# SCOPE, stated because the asymmetry is invisible otherwise: this reaches the
# GENERATE arm only. The embed arm posts to /v1/embeddings, the OpenAI-compatible
# endpoint, which has no options field to carry num_gpu — so under --force-lane
# the generate numbers are a real per-lane measurement and the embed numbers are
# whatever the runtime chose, in BOTH arms. The observation below reports what
# actually ran, so this does not become a silent mislabel; but do not read a
# forced run's embed column as a CPU-vs-GPU comparison.
LANE_OPTS='{}'
if [ "$FORCE_LANE" -eq 1 ]; then
    case "$LANE" in
        cpu) LANE_OPTS='{"num_gpu":0}' ;;
        gpu|npu) LANE_OPTS='{}' ;;
        *) echo "bench-accel-lane: --force-lane does not know lane '$LANE'" >&2; exit 2 ;;
    esac
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/bench-accel.XXXXXX")" || exit 2
trap 'rm -rf "$work"' EXIT

# A DETERMINISTIC sample, so two hosts measure the same text. Taking the first N
# non-trivial chunks is reproducible; a random sample would make the matrix
# incomparable for no benefit.
jq -c 'select((.text | length) > 40) | .text' "$CHUNKS" | head -n "$N" > "$work/sample.jsonl"
got="$(wc -l < "$work/sample.jsonl" | tr -d '[:space:]')"
[ "$got" -gt 0 ] || { echo "bench-accel-lane: sample is empty" >&2; exit 2; }

p50_chars="$(jq -r 'length' "$work/sample.jsonl" | sort -n | awk '{a[NR]=$1} END{print a[int(NR/2)+1]}')"

# TIMED BY CURL, not by the shell. `date +%s%3N` is a GNU-ism that BSD date
# accepts while emitting garbage (761-g36m / 784-dwkh: the exit-code guard never
# fires because BSD date SUCCEEDS), so a macOS host would have produced
# confident nonsense here. curl's own %{time_total} is portable, and it is the
# better instrument anyway: it measures the request, excluding the jq and
# process-spawn overhead that shell-side timestamps fold into every sample.
_req_ms() {
    # $1 = url, $2 = json body file. Prints integer milliseconds.
    local secs
    secs="$(curl -fsS --max-time 120 -o /dev/null -w '%{time_total}' \
        "$1" -H 'Content-Type: application/json' -d @"$2" 2>/dev/null)" || secs=""
    [ -n "$secs" ] || { echo "-1"; return 0; }
    awk -v s="$secs" 'BEGIN { printf "%d\n", (s * 1000) + 0.5 }'
}

# ── evict the generate model before the run (--force-lane only) ─────────────
# A loaded model KEEPS THE CONFIGURATION IT WAS LOADED WITH. Ask the same server
# for the cpu lane and then the gpu lane inside the keep-alive window and the
# second run silently reuses the first one's placement — so the numbers are one
# lane measured twice and `/api/ps` reports the STALE residency, confirming the
# label rather than checking it.
#
# MEASURED on tlatoanis-macbook-air 2026-09-03 while wiring this: after a
# num_gpu:0 run, a default (Metal) request came back still reporting
# size_vram=0. Evicting first, the same request reports
# size_vram=479954205 == size, i.e. fully resident. Same server, same request,
# opposite conclusions — decided entirely by what was cached.
#
# keep_alive:0 unloads immediately. Only under --force-lane: the two-server
# callers this script was written for have nothing to evict.
if [ "$FORCE_LANE" -eq 1 ]; then
    jq -nc --arg m "$GEN_MODEL" '{model:$m, keep_alive:0}' > "$work/evict.json"
    curl -fsS --max-time 30 "$ENDPOINT/api/generate" -H 'Content-Type: application/json' \
        -d @"$work/evict.json" >/dev/null 2>&1 || true
    sleep 2
fi

# ── warm-up, discarded ──────────────────────────────────────────────────────
head -1 "$work/sample.jsonl" | while IFS= read -r t; do
    jq -nc --arg m "$EMBED_MODEL" --argjson i "$t" '{model:$m, input:$i}' > "$work/warm.json"
done
curl -fsS --max-time 120 "$ENDPOINT/v1/embeddings" -H 'Content-Type: application/json' \
    -d @"$work/warm.json" >/dev/null 2>&1 || true

# ── embed arm: per-chunk wall time, one request per chunk ───────────────────
embed_medians=""
embed_failed=""
rep=1
while [ "$rep" -le "$REPS" ]; do
    : > "$work/times.txt"
    while IFS= read -r t; do
        jq -nc --arg m "$EMBED_MODEL" --argjson i "$t" '{model:$m, input:$i}' > "$work/req.json"
        _req_ms "$ENDPOINT/v1/embeddings" "$work/req.json" >> "$work/times.txt"
    done < "$work/sample.jsonl"
    # A failed request records -1 and is EXCLUDED from the median rather than
    # counted as instant. Silently dropping it would be worse: the count is
    # reported alongside so a degraded rep is visible instead of averaged away.
    failed="$(grep -c '^-1$' "$work/times.txt" || true)"
    med="$(grep -v '^-1$' "$work/times.txt" | sort -n | awk '{a[NR]=$1} END{if (NR>0) print a[int(NR/2)+1]; else print -1}')"
    embed_failed="${embed_failed:+$embed_failed,}${failed:-0}"
    embed_medians="${embed_medians:+$embed_medians,}$med"
    rep=$((rep + 1))
done

# ── generate arm: decode-shaped, tokens/s from the server's own counters ────
# eval_count / eval_duration is the DECODE rate as the server measured it, which
# is not the same as wall/tokens — wall includes prompt processing and HTTP, and
# conflating them is how a decode claim gets made from a prefill-dominated
# number.
gen_tps=""
gen_ptps=""
rep=1
while [ "$rep" -le "$REPS" ]; do
    # A DISTINCT PROMPT PER REP, or the prefill column is fiction. The server
    # caches the processed prompt, so an identical prompt on rep 2 skips prefill
    # almost entirely and prompt_eval_duration collapses. MEASURED on
    # tlatoanis-macbook-air 2026-09-03 with the fixed prompt: rep1 521 prefill
    # tok/s, rep2 6274 — a 12x "speedup" that is the cache, not the hardware,
    # and it would have been averaged into a routing decision. Decode is
    # unaffected (nothing caches generated tokens), which is why only this half
    # needed changing.
    #
    # The prefix keeps every rep the same TOKEN LENGTH and the same shape, so
    # the reps stay comparable to each other and across hosts; only the cache
    # key differs.
    _rep_prompt="rep $rep of $REPS. $GEN_PROMPT"
    jq -nc --arg m "$GEN_MODEL" --arg p "$_rep_prompt" --argjson n "$GEN_TOKENS" \
        --argjson lo "$LANE_OPTS" \
        '{model:$m, prompt:$p, stream:false, options:({num_predict:$n} + $lo)}' > "$work/gen.json"
    if curl -fsS --max-time 300 "$ENDPOINT/api/generate" -H 'Content-Type: application/json' \
        -d @"$work/gen.json" > "$work/gen-resp.json" 2>/dev/null; then
        tps="$(jq -r 'if (.eval_duration // 0) > 0 then ((.eval_count // 0) / (.eval_duration / 1000000000)) else 0 end' "$work/gen-resp.json" 2>/dev/null)"
        # PREFILL from the server's own prompt counters. Both halves come from
        # one response on purpose: prefill and decode measured in separate runs
        # are two different cache states, and the whole routing question is the
        # RATIO between them.
        ptps="$(jq -r 'if (.prompt_eval_duration // 0) > 0 then ((.prompt_eval_count // 0) / (.prompt_eval_duration / 1000000000)) else 0 end' "$work/gen-resp.json" 2>/dev/null)"
    else
        tps="0"; ptps="0"
    fi
    gen_tps="${gen_tps:+$gen_tps,}${tps:-0}"
    gen_ptps="${gen_ptps:+$gen_ptps,}${ptps:-0}"
    rep=$((rep + 1))
done

# ── what the lane REPORTED, not what we asked for ───────────────────────────
# The arm is labelled by observation. An intent-labelled arm is exactly how a
# failed-to-start GPU server got recorded as a GPU result.
# ASK ABOUT THE GENERATE MODEL, NOT ABOUT WHATEVER IS LOADED. This used to take
# `max` over every resident model, which on a one-server host answers about the
# EMBED model — nomic-embed-text, loaded by the embed arm moments earlier and
# GPU-resident regardless of the lane under test. Measured while wiring
# --force-lane on 2026-09-03: a genuine CPU run (num_gpu:0, the generate model
# at size_vram=0) reported `gpu-resident:370031984`, which is the embedder.
#
# So the check that exists to refuse an intent-labelled arm was itself answering
# about a different model, and it failed toward "gpu" — the direction that
# confirms the label. Selecting by name makes it answer the question it claims
# to: the arm is labelled by observing THE MODEL THE ARM MEASURED.
#
# `residency` reports both halves, because size_vram alone cannot distinguish
# "no offload" from "not loaded", and a partial offload is a third state that a
# boolean would hide.
observed="unknown"
if ps_json="$(curl -fsS --max-time 10 "$ENDPOINT/api/ps" 2>/dev/null)"; then
    vram="$(printf '%s' "$ps_json" \
        | jq -r --arg m "$GEN_MODEL" '[.models[]? | select(.name == $m or .model == $m) | .size_vram // 0] | max // 0' 2>/dev/null)"
    total="$(printf '%s' "$ps_json" \
        | jq -r --arg m "$GEN_MODEL" '[.models[]? | select(.name == $m or .model == $m) | .size // 0] | max // 0' 2>/dev/null)"
    case "${vram:-0}" in
        ''|0)
            if [ "${total:-0}" = "0" ]; then
                observed="unloaded"
            else
                observed="cpu-resident:0/${total}"
            fi
            ;;
        *)
            if [ "${vram}" = "${total}" ]; then
                observed="gpu-resident:${vram}/${total}"
            else
                observed="gpu-partial:${vram}/${total}"
            fi
            ;;
    esac
fi

# ORDER 805-wgbb. With --record, the numbers land in the capability document
# instead of only on stdout. The mapping is deliberately partial and says so:
# MeasurementRecord has prefill_tps/decode_tps/joules_per_token and NO latency
# or workload field, so the embed ms-per-chunk -- the statistic that decides the
# embed lane -- has nowhere to live in it yet. That gap is the open half of
# 805-wgbb; recording the half that fits beats recording nothing, and pretending
# ms/chunk is a tps would be worse than both.
if [ "${RECORD:-0}" = "1" ]; then
    # RESOLVE THE CHECKOUT BUILD FIRST. `tillandsias` on PATH is the INSTALLED
    # release, and --record-measurement lives in the checkout until the next
    # release ships — so calling PATH here fails with "Unsupported option" on
    # every host, which is exactly what happened the first time this ran. Same
    # class as 783-6rik: a checkout-side caller reaching for a release-side
    # binary. The fresh artifact outranks the stale install, and if neither has
    # the flag the caller still gets its numbers on stdout.
    _bench_tillandsias="$ROOT_DIR/target/release/tillandsias"
    [ -x "$_bench_tillandsias" ] || _bench_tillandsias="$ROOT_DIR/target/debug/tillandsias"
    [ -x "$_bench_tillandsias" ] || _bench_tillandsias="$(command -v tillandsias 2>/dev/null || echo tillandsias)"
    _bench_decode="$(printf '%s' "$gen_tps" | tr ',' '\n' | sort -n | awk '{a[NR]=$1} END{if (NR>0) print a[int(NR/2)+1]; else print 0}')"
    _bench_prefill="$(printf '%s' "$gen_ptps" | tr ',' '\n' | sort -n | awk '{a[NR]=$1} END{if (NR>0) print a[int(NR/2)+1]; else print 0}')"
    # The arm is labelled by what the lane REPORTED, so a run that silently fell
    # back is recorded degraded rather than as a clean number for a lane it
    # never used.
    _bench_degraded=false
    _bench_reason=null
    # The observation vocabulary changed with --force-lane (cpu-resident /
    # gpu-resident / gpu-partial / unloaded), so this matches on PREFIX rather
    # than on the single old literal `cpu-or-unloaded`, which no longer occurs
    # and would have silently stopped ever marking a run degraded.
    #
    # gpu-partial is degraded too, and that is not pedantry: a model half on the
    # GPU is neither device's number, and recording it as a clean `gpu` result
    # would move a crossover threshold on the strength of a split placement.
    case "$LANE" in
        gpu)
            case "$observed" in
                cpu-resident:*|unloaded|unknown)
                    _bench_degraded=true
                    _bench_reason='"requested gpu but the runner reported no VRAM-resident model"'
                    ;;
                gpu-partial:*)
                    _bench_degraded=true
                    _bench_reason='"requested gpu but the model was only partially offloaded"'
                    ;;
            esac
            ;;
        cpu)
            case "$observed" in
                gpu-resident:*|gpu-partial:*)
                    _bench_degraded=true
                    _bench_reason='"requested cpu but the runner offloaded to the GPU"'
                    ;;
            esac
            ;;
    esac
    # An unset locus is sent as JSON null rather than omitted, so the payload
    # shape is the same either way and a reader never has to distinguish
    # "absent key" from "null value" to reach the same conclusion: unknown.
    _bench_locus=null
    [ -n "$LOCUS" ] && _bench_locus="$(jq -n --arg l "$LOCUS" '$l')"
    # Older binaries ignore unknown fields (serde default), so sending these to
    # a release that predates schema_version 2 is a no-op rather than a break.
    # THE PARAMETER AXIS, without which the crossover cannot be derived at all
    # (order 793-qc6q). `decode_crossover_b` skips any record whose
    # `model_params_b` is None, so every number recorded before this line was
    # usable for reporting and invisible to routing — the reason every host in
    # the fleet read `Unmeasured` while measurements existed.
    #
    # Parsed from the model tag rather than passed by hand: the tag is what the
    # caller already types, and a hand-passed size is a second source of truth
    # that can disagree with the model actually benchmarked. Ollama's convention
    # is `<family>:<size>b` (qwen2.5:0.5b, qwen2.5:7b), so the size is IN the
    # name; --model-params-b overrides for a tag that does not carry one.
    if [ -z "$MODEL_PARAMS_B" ]; then
        MODEL_PARAMS_B="$(printf '%s' "$GEN_MODEL" \
            | tr 'A-Z' 'a-z' \
            | sed -n 's/.*:\([0-9][0-9]*\(\.[0-9][0-9]*\)*\)b.*/\1/p')"
    fi
    # Absent stays ABSENT, never 0: a 0 would be a claim that the model has no
    # parameters, and it would sort below every real size in the crossover scan.
    _bench_params=null
    [ -n "$MODEL_PARAMS_B" ] && _bench_params="$MODEL_PARAMS_B"
    jq -nc --arg d "$LANE" --arg e "ollama" \
        --argjson p "${_bench_prefill:-0}" --argjson dec "${_bench_decode:-0}" \
        --argjson deg "$_bench_degraded" --argjson reason "$_bench_reason" \
        --arg suite "$WORKLOAD_SUITE" --argjson locus "$_bench_locus" \
        --arg model "$GEN_MODEL" --argjson params "$_bench_params" \
        '{device:$d, engine:$e, prefill_tps:$p, decode_tps:$dec, joules_per_token:null, degraded:$deg, degraded_reason:$reason, workload_suite:$suite, locus:$locus, model:$model, model_params_b:$params}' \
        | "$_bench_tillandsias" --record-measurement - >&2 || \
        echo "note:bench-accel-lane:record-failed (numbers still on stdout)" >&2
fi

jq -nc \
    --arg lane "$LANE" \
    --arg observed "$observed" \
    --arg endpoint "$ENDPOINT" \
    --arg embed_model "$EMBED_MODEL" \
    --arg gen_model "$GEN_MODEL" \
    --argjson n "$got" \
    --argjson reps "$REPS" \
    --argjson p50_chars "$p50_chars" \
    --argjson embed_ms_per_chunk_medians "[$embed_medians]" \
    --argjson embed_failed_per_rep "[$embed_failed]" \
    --argjson gen_tokens_per_s "[$gen_tps]" \
    --argjson gen_prefill_tps "[$gen_ptps]" \
    --arg suite "$WORKLOAD_SUITE" \
    --argjson locus_out "$( [ -n "$LOCUS" ] && jq -n --arg l "$LOCUS" '$l' || echo null )" \
    '{
       workload_suite: $suite,
       locus: $locus_out,
       lane_requested: $lane,
       lane_observed: $observed,
       endpoint: $endpoint,
       sample: { chunks: $n, p50_chars: $p50_chars, reps: $reps, source: "spec-index chunks.jsonl" },
       embed: { model: $embed_model, ms_per_chunk_median_per_rep: $embed_ms_per_chunk_medians, failed_requests_per_rep: $embed_failed_per_rep },
       generate: { model: $gen_model, decode_tps_per_rep: $gen_tokens_per_s, prefill_tps_per_rep: $gen_prefill_tps }
     }'
exit 0
