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
#   scripts/bench-accel-lane.sh --lane cpu [--endpoint http://127.0.0.1:11434]
#                               [--chunks <chunks.jsonl>] [--n 40] [--reps 3]
#                               [--embed-model nomic-embed-text]
#                               [--gen-model qwen2.5:0.5b]
set -uo pipefail

LANE=""
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
EMBED_MODEL="nomic-embed-text"
GEN_MODEL="qwen2.5:0.5b"
GEN_PROMPT="Summarize the purpose of a container enclave in two sentences."
GEN_TOKENS=64

while [ $# -gt 0 ]; do
    case "$1" in
        --lane) LANE="${2:-}"; shift 2 ;;
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
    jq -nc --arg m "$GEN_MODEL" --arg p "$GEN_PROMPT" --argjson n "$GEN_TOKENS" \
        '{model:$m, prompt:$p, stream:false, options:{num_predict:$n}}' > "$work/gen.json"
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
observed="unknown"
if ps_json="$(curl -fsS --max-time 10 "$ENDPOINT/api/ps" 2>/dev/null)"; then
    vram="$(printf '%s' "$ps_json" | jq -r '[.models[]?.size_vram // 0] | max // 0' 2>/dev/null)"
    case "$vram" in
        ''|0) observed="cpu-or-unloaded" ;;
        *) observed="gpu-resident:${vram}" ;;
    esac
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
    '{
       workload_suite: "802-2536-v1",
       lane_requested: $lane,
       lane_observed: $observed,
       endpoint: $endpoint,
       sample: { chunks: $n, p50_chars: $p50_chars, reps: $reps, source: "spec-index chunks.jsonl" },
       embed: { model: $embed_model, ms_per_chunk_median_per_rep: $embed_ms_per_chunk_medians, failed_requests_per_rep: $embed_failed_per_rep },
       generate: { model: $gen_model, decode_tps_per_rep: $gen_tokens_per_s, prefill_tps_per_rep: $gen_prefill_tps }
     }'
exit 0
