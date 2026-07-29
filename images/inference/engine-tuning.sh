#!/bin/sh
# @trace spec:inference-container
# order 406 — inference-cuda-bringup-fat-host (engine tuning slice)
#
# Accelerator-tuned engine settings for the Tillandsias inference container.
#
# WHY A SEPARATE FILE: same discipline as preload-policy.sh (order 392a) — the
# policy has to be FALSIFIABLE without booting a container. This is POSIX sh
# with no side effects beyond setting/exporting shell variables and printing one
# line, so entrypoint.sh can `.` (source) it while
# litmus:inference-engine-tuning-policy runs it standalone with stubbed inputs
# and asserts every branch. No python, no eval of untrusted text.
#
# PINNED GRAMMAR — exactly one line, always exit 0:
#   tuning: tier=<tier> flash_attn=<0|1> kv_cache=<f16|q8_0> num_parallel=<N> vram_mb=<N>
#
# ── Why these values (MEASURED, not assumed) ─────────────────────────────
# Live A/B on macuahuitl 2026-07-29 (RTX A5000 24 GB, driver 610.43.03,
# CUDA UMD 13.3, ollama cuda_v13 backend, qwen2.5:7b Q4_K_M, n_ctx 32768,
# 200-token generations, warm runs only):
#
#   flash_attn=off kv_cache=f16   105.9 tok/s   8098 MiB VRAM
#   flash_attn=on  kv_cache=q8_0  106.8-107.7 tok/s   5690 MiB VRAM
#
# Throughput is unchanged within noise; VRAM drops 30% (2408 MiB) at the SAME
# context length. That headroom is the point: the EXPERTS milestone (391) keeps
# several ephemeral expert models resident at once, and each 2.4 GB saved is
# most of another 7B expert slot. So on CUDA this is a free win and is enabled.
#
# It is NOT enabled on the vulkan/rocm lanes: flash attention there was not
# measured on this host, and claiming an unmeasured win is exactly the kind of
# "GPU tier in name only" the order-392 boundary rules forbid. Those lanes stay
# on the conservative f16 path until a host with that accelerator measures them
# (orders 410, 481, 482).
#
# ── Overrides ───────────────────────────────────────────────────────────
# An operator-supplied OLLAMA_FLASH_ATTENTION / OLLAMA_KV_CACHE_TYPE /
# OLLAMA_NUM_PARALLEL is respected VERBATIM and reported in the line, so the
# emitted state always describes what ollama will actually run.
# TILLANDSIAS_TUNING_VRAM_MB stubs the VRAM reading (litmus/dev only).

# ── Inputs ──────────────────────────────────────────────────────────────
TUNING_TIER="${TILLANDSIAS_INFERENCE_TIER:-cpu}"

# Total VRAM in MB. Stubbable so every branch is testable without a matching host.
TUNING_VRAM_MB="${TILLANDSIAS_TUNING_VRAM_MB:-}"
if [ -z "$TUNING_VRAM_MB" ]; then
    if command -v nvidia-smi >/dev/null 2>&1; then
        TUNING_VRAM_MB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
            | head -n1 | tr -d ' ')"
    fi
fi
case "$TUNING_VRAM_MB" in
    '' | *[!0-9]*) TUNING_VRAM_MB=0 ;;
esac

# ── Policy ──────────────────────────────────────────────────────────────
# Defaults are the conservative CPU-safe path; the CUDA branch opts in to the
# measured wins above.
_tuning_flash=0
_tuning_kv=f16
_tuning_parallel=1

case "$TUNING_TIER" in
    gpu-cuda)
        _tuning_flash=1
        _tuning_kv=q8_0
        # Concurrency is bounded by VRAM, not by core count: each parallel slot
        # gets its own KV cache allocation. An agent-facing expert endpoint wants
        # a couple of concurrent queries, not maximum batch throughput.
        if [ "$TUNING_VRAM_MB" -ge 16384 ]; then
            _tuning_parallel=4
        elif [ "$TUNING_VRAM_MB" -ge 8192 ]; then
            _tuning_parallel=2
        else
            # Mobile / small discrete GPU: one slot. Splitting 4-8 GB across
            # parallel KV caches is how a GPU tier starts spilling to host RAM
            # and ends up slower than the CPU lane it replaced.
            _tuning_parallel=1
        fi
        ;;
    gpu-rocm | gpu-vulkan)
        # Unmeasured on this host — stay on the validated conservative path.
        _tuning_flash=0
        _tuning_kv=f16
        _tuning_parallel=1
        ;;
    *)
        # cpu / metal / anything unrecognised: conservative, and NEVER a
        # GPU-shaped claim. An unknown tier degrades like cpu (fail-soft).
        _tuning_flash=0
        _tuning_kv=f16
        _tuning_parallel=1
        ;;
esac

# ── Operator overrides win verbatim ─────────────────────────────────────
# ollama reads these once at process start, so they must be exported BEFORE
# `ollama serve`. Report whatever will actually take effect.
if [ -n "${OLLAMA_FLASH_ATTENTION:-}" ]; then
    case "$OLLAMA_FLASH_ATTENTION" in
        1 | true | TRUE | on) _tuning_flash=1 ;;
        *) _tuning_flash=0 ;;
    esac
fi
if [ -n "${OLLAMA_KV_CACHE_TYPE:-}" ]; then
    case "$OLLAMA_KV_CACHE_TYPE" in
        f16 | q8_0 | q4_0) _tuning_kv="$OLLAMA_KV_CACHE_TYPE" ;;
        # An unrecognised cache type would make llama-server refuse to start;
        # degrade to the safe default rather than take the endpoint down.
        *) _tuning_kv=f16 ;;
    esac
fi
if [ -n "${OLLAMA_NUM_PARALLEL:-}" ]; then
    case "$OLLAMA_NUM_PARALLEL" in
        '' | *[!0-9]*) ;;
        0) ;;
        *) _tuning_parallel="$OLLAMA_NUM_PARALLEL" ;;
    esac
fi

# A quantised KV cache requires flash attention in llama.cpp; the pair is not
# independently selectable. Rather than let llama-server fail to start on a
# half-applied combination, drop back to f16 and say so in the line.
if [ "$_tuning_flash" -eq 0 ] && [ "$_tuning_kv" != "f16" ]; then
    _tuning_kv=f16
fi

if [ "$_tuning_flash" -eq 1 ]; then
    OLLAMA_FLASH_ATTENTION=1
else
    OLLAMA_FLASH_ATTENTION=0
fi
OLLAMA_KV_CACHE_TYPE="$_tuning_kv"
OLLAMA_NUM_PARALLEL="$_tuning_parallel"
export OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE OLLAMA_NUM_PARALLEL

# ── Compose the pinned line ─────────────────────────────────────────────
TUNING_LINE="tuning: tier=${TUNING_TIER} flash_attn=${_tuning_flash} kv_cache=${_tuning_kv} num_parallel=${_tuning_parallel} vram_mb=${TUNING_VRAM_MB}"

# Run directly (litmus / operator diagnostics) vs sourced by entrypoint.sh:
# when this file IS the program, $0 ends in its own basename. Sourced, it stays
# silent so the entrypoint owns a single `[inference] tuning: …` log line.
case "${0##*/}" in
    engine-tuning.sh | tillandsias-engine-tuning.sh)
        printf '%s\n' "$TUNING_LINE"
        ;;
esac
