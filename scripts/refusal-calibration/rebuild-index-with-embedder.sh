#!/usr/bin/env bash
# rebuild-index-with-embedder.sh — rebuild the spec index under a named
# embedder, with the model loads SERIALISED and the GPU state recorded beside
# every timing.
#
# WHY BOTH OF THOSE, AND WHY IN ONE SCRIPT.
#
# SERIALISATION. 849-tz8g was filed claiming an inference-image size ceiling:
# mxbai-embed-large, batched bge-m3 and qwen3-embedding:4b all died with
# `llama-server … signal: aborted`. That was WRONG and I filed it. Every one of
# those loads happened while another model was already resident. The real
# defect is CONCURRENT RUNNER RESIDENCY — with ~7,910 MiB across two models a
# third load dies with GGML_ASSERT while sixteen gigabytes are free. The
# failure names memory and is not about memory, which is why it read as a size
# limit for as long as it did. This script unloads everything first, so the
# workaround is executed rather than described.
#
# GPU RECORDING. The operator games on this host. A latency measured while a
# game holds the GPU is wrong in a way that looks exactly like a slow model, and
# this campaign has already been caught by it once. So utilisation and VRAM are
# sampled before, throughout, and after — an embedding benchmark from this host
# without that column is not admissible evidence, and the way to guarantee the
# column exists is to make the harness take it rather than the operator
# remember to.
#
# Output: a TSV of phase timings on stdout, GPU samples to <out>/gpu-samples.tsv,
# and one falsifiable verdict line:
#   ok:index-rebuilt:<model>:<fingerprint>:<seconds>
#   blocked:index-rebuild:<reason>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

ENDPOINT="${TILLANDSIAS_INFERENCE_ENDPOINT:-http://127.0.0.1:11434}"
MODEL=""
BATCH="${TILLANDSIAS_SPEC_INDEX_BATCH:-64}"
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --model) MODEL="$2"; shift 2 ;;
        --batch) BATCH="$2"; shift 2 ;;
        --out)   OUT="$2"; shift 2 ;;
        --help|-h)
            echo "usage: rebuild-index-with-embedder.sh --model M [--batch N] [--out DIR]"
            exit 0 ;;
        *) echo "error: unknown argument $1" >&2; exit 2 ;;
    esac
done

[ -n "$MODEL" ] || { echo "blocked:index-rebuild:no-model-named"; exit 2; }
[ -n "$OUT" ] || OUT="target/index-rebuild/$(echo "$MODEL" | tr ':/' '__')"
mkdir -p "$OUT"

# CONTAMINATION_MIB — how much VRAM a non-ollama client must hold before this
# run is called contaminated. NOT zero, and the first version of this script
# got that wrong: it flagged the mere PRESENCE of a non-ollama compute client
# and instantly reported 4 on an idle machine, because gnome-remote-desktop,
# gnome-software, gnome-calendar and ptyxis all hold a few MiB for ordinary
# desktop compositing. A contamination flag that fires on every run is not a
# safeguard, it is noise that trains you to ignore it — the same failure shape
# as a gate nobody has seen go red. A game holds gigabytes; desktop chrome
# holds tens of MiB. Threshold between them.
CONTAMINATION_MIB="${TILLANDSIAS_GPU_CONTAMINATION_MIB:-800}"

gpu_sample() {
    # utilisation%, total VRAM, and the VRAM held by NON-ollama clients — the
    # last column is what makes the timing falsifiable.
    local util others
    util="$(nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader 2>/dev/null | tr -d ' %')"
    others="$(nvidia-smi --query-compute-apps=process_name,used_memory --format=csv,noheader 2>/dev/null \
              | grep -vE 'llama-server|ollama' \
              | awk -F',' '{gsub(/[^0-9]/,"",$2); s += $2+0} END {print s+0}')"
    printf '%s\t%s\t%s\n' "$(date -u +%H:%M:%S)" "${util:-NA}" "${others:-0}"
}

echo -e "ts\tutil_mem\tnon_ollama_vram_mib" > "$OUT/gpu-samples.tsv"
gpu_sample >> "$OUT/gpu-samples.tsv"

# ── SERIALISE: unload every resident model before loading the target ────────
resident_before="$(curl -s "$ENDPOINT/api/ps" 2>/dev/null \
    | grep -oE '"model":"[^"]+"' | sed 's/"model":"//;s/"//' | sort -u)"
echo "resident before: ${resident_before:-<none>}" >&2
for m in $resident_before; do
    # keep_alive 0 is the documented eviction: it returns once the runner is
    # released rather than merely scheduling it.
    curl -s "$ENDPOINT/api/generate" \
        -d "{\"model\":\"$m\",\"keep_alive\":0,\"prompt\":\"\"}" >/dev/null 2>&1
done
sleep 3
resident_after="$(curl -s "$ENDPOINT/api/ps" 2>/dev/null \
    | grep -oE '"model":"[^"]+"' | sed 's/"model":"//;s/"//' | sort -u)"
if [ -n "$resident_after" ]; then
    echo "warn: still resident after eviction: $resident_after" >&2
fi
gpu_sample >> "$OUT/gpu-samples.tsv"

# Background sampler for the duration — a single before/after pair cannot see a
# game that starts mid-run, which is the case that would silently poison this.
( while :; do gpu_sample >> "$OUT/gpu-samples.tsv"; sleep 15; done ) &
SAMPLER=$!
cleanup() { kill "$SAMPLER" 2>/dev/null; }
trap cleanup EXIT INT TERM

start=$(date +%s)
TILLANDSIAS_EMBED_MODEL="$MODEL" \
TILLANDSIAS_SPEC_INDEX_BATCH="$BATCH" \
    scripts/spec-index-ensure.sh > "$OUT/build.log" 2>&1
rc=$?
end=$(date +%s)
elapsed=$(( end - start ))

cleanup
gpu_sample >> "$OUT/gpu-samples.tsv"

# Contamination verdict: if any sample saw a non-ollama compute client, the
# timing is contaminated and must be reported as such, not quietly used.
contaminated="$(awk -F'\t' -v lim="$CONTAMINATION_MIB" \
    'NR>1 && $3+0 > lim {n++} END {print n+0}' "$OUT/gpu-samples.tsv")"
peak_other="$(awk -F'\t' 'NR>1 {if ($3+0 > m) m = $3+0} END {print m+0}' "$OUT/gpu-samples.tsv")"
peakutil="$(awk -F'\t' 'NR>1 {split($2,a,","); if (a[1]+0 > m) m = a[1]+0} END {print m+0}' "$OUT/gpu-samples.tsv")"

printf 'phase\tseconds\n'            >  "$OUT/timings.tsv"
printf 'index-rebuild\t%s\n' "$elapsed" >> "$OUT/timings.tsv"
printf 'model\t%s\n' "$MODEL"        >> "$OUT/timings.tsv"
printf 'batch\t%s\n' "$BATCH"        >> "$OUT/timings.tsv"
printf 'peak_gpu_util_pct\t%s\n' "$peakutil"      >> "$OUT/timings.tsv"
printf 'peak_non_ollama_vram_mib\t%s\n' "$peak_other" >> "$OUT/timings.tsv"
printf 'contamination_threshold_mib\t%s\n' "$CONTAMINATION_MIB" >> "$OUT/timings.tsv"
printf 'contaminated_samples\t%s\n' "$contaminated" >> "$OUT/timings.tsv"
cat "$OUT/timings.tsv"

if [ "$rc" -ne 0 ]; then
    echo "blocked:index-rebuild:builder-exit-$rc (see $OUT/build.log)"
    exit 1
fi
if [ "$contaminated" -gt 0 ]; then
    echo "warn: $contaminated GPU sample(s) saw a non-ollama compute client — this timing is CONTAMINATED" >&2
fi
IDXROOT="${TILLANDSIAS_SPEC_INDEX_ROOT:-$HOME/.local/share/containers/storage/volumes/tillandsias-spec-index-tillandsias/_data}"
fp="$(tr -d '[:space:]' < "$IDXROOT/current" 2>/dev/null)"
echo "ok:index-rebuilt:$MODEL:${fp:-unknown}:$elapsed"
