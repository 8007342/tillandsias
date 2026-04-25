#!/bin/bash
set -e
# @trace spec:inference-container
# Entrypoint for the Tillandsias inference container.
# Starts ollama listening on all interfaces so forge containers can reach it.
# DISTRO: Fedora Minimal 43 — has curl (NOT wget), bash, pciutils.
#         Rust health checks use curl, not wget (see handlers.rs).

# Bind to all interfaces — reachable from other containers in the enclave.
export OLLAMA_HOST=0.0.0.0:11434

# Shared model cache — persisted via volume mount.
export OLLAMA_MODELS=/home/ollama/.ollama/models/

# @trace spec:inference-container
# Detect GPU at runtime (devices passed through via --device flags)
GPU_STATUS="CPU only"
if [ -e /dev/nvidia0 ]; then
    GPU_STATUS="NVIDIA ($(ls /dev/nvidia[0-9]* 2>/dev/null | wc -l) device(s))"
elif [ -e /dev/kfd ]; then
    GPU_STATUS="AMD ROCm"
fi

echo "========================================"
echo "  tillandsias inference"
echo "  listening on :11434"
echo "  models:  $OLLAMA_MODELS"
echo "  GPU:     $GPU_STATUS"
echo "========================================"

# @trace spec:inference-container, spec:zen-default-with-ollama-analysis-pool
# Seed the bind-mounted models cache from /opt/baked-models/ if T0/T1
# manifests aren't already present in the cache. The cache survives
# container restarts (host-mounted volume), so this only fires the first
# time on a host that's never run a forge before.
if [ -d /opt/baked-models ]; then
    BAKED_MANIFEST=/opt/baked-models/manifests/registry.ollama.ai/library/qwen2.5/0.5b
    USER_MANIFEST=$OLLAMA_MODELS/manifests/registry.ollama.ai/library/qwen2.5/0.5b
    if [ -f "$BAKED_MANIFEST" ] && [ ! -f "$USER_MANIFEST" ]; then
        echo "[inference] Seeding model cache from /opt/baked-models (first run)..."
        # cp -an: archive (preserve perms/links) + no-clobber. tar fallback if cp -n unsupported.
        cp -an /opt/baked-models/. "$OLLAMA_MODELS/" 2>/dev/null \
            || (cd /opt/baked-models && tar cf - . | tar xf - -C "$OLLAMA_MODELS")
        echo "[inference] Cache seeded"
    fi
fi

# @trace spec:inference-container
# Start ollama in background so we can pre-pull models before going live.
ollama serve &
OLLAMA_PID=$!

# Wait for ollama to accept connections.
for i in $(seq 1 30); do
    if ollama list &>/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# ── Tier-tagged tool-capable model pre-pulls ────────────────────
# @trace spec:inference-container, spec:zen-default-with-ollama-analysis-pool
# T0 (qwen2.5:0.5b) and T1 (llama3.2:3b) are baked into the image at build
# time so the first attach has them locally. T2+ pull at runtime if the
# host has the headroom, and pull failures stay non-fatal — Squid SSL bump
# tends to EOF on big ollama manifest pulls (see project memory:
# project_squid_ollama_eof.md). All tiers ship tool-capable models;
# tinyllama et al are out because they don't follow tool-call schemas.

# Detect runtime tier from RAM (CPU) and GPU VRAM, pick the highest.
RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
VRAM_GB=$(( ${VRAM_MB:-0} / 1024 ))

TIER="T1"
if [ "$VRAM_GB" -ge 32 ]; then TIER="T5"
elif [ "$VRAM_GB" -ge 16 ]; then TIER="T4"
elif [ "$VRAM_GB" -ge 8 ] || [ "$RAM_GB" -ge 32 ]; then TIER="T3"
elif [ "$VRAM_GB" -ge 4 ] || [ "$RAM_GB" -ge 16 ]; then TIER="T2"
fi

echo "[inference] tier=$TIER (RAM ${RAM_GB}GB, VRAM ${VRAM_GB}GB)"

# T0 + T1 are image-baked; just confirm they're present.
ollama list 2>/dev/null | grep -q "qwen2.5:0.5b" \
    && echo "[inference] T0 (qwen2.5:0.5b) ready" \
    || echo "[inference] T0 (qwen2.5:0.5b) MISSING — image build did not bake it" >&2
ollama list 2>/dev/null | grep -q "llama3.2:3b" \
    && echo "[inference] T1 (llama3.2:3b) ready" \
    || echo "[inference] T1 (llama3.2:3b) MISSING — image build did not bake it" >&2

# T2+ pull in background if tier permits.
case "$TIER" in
    T5|T4|T3|T2)
        (
            [ "$TIER" != "T0" ] && [ "$TIER" != "T1" ] && \
                ollama pull qwen2.5:7b \
                && echo "[inference] T2 (qwen2.5:7b) ready" \
                || echo "[inference] T2 (qwen2.5:7b) pull failed (squid SSL-bump EOF likely; non-fatal)" >&2
            case "$TIER" in T5|T4|T3)
                ollama pull qwen2.5-coder:7b \
                    && echo "[inference] T3 (qwen2.5-coder:7b) ready" \
                    || echo "[inference] T3 (qwen2.5-coder:7b) pull failed (non-fatal)" >&2
            esac
            case "$TIER" in T5|T4)
                ollama pull qwen2.5:14b \
                    && echo "[inference] T4 (qwen2.5:14b) ready" \
                    || echo "[inference] T4 (qwen2.5:14b) pull failed (non-fatal)" >&2
            esac
            case "$TIER" in T5)
                ollama pull qwen2.5-coder:32b \
                    && echo "[inference] T5 (qwen2.5-coder:32b) ready" \
                    || echo "[inference] T5 (qwen2.5-coder:32b) pull failed (non-fatal)" >&2
            esac
            echo "[inference] runtime tier pulls complete"
        ) &
        ;;
    *)
        echo "[inference] tier=T0/T1 only — no runtime pulls"
        ;;
esac

# Hand off to ollama as the foreground process for signal handling.
wait $OLLAMA_PID
