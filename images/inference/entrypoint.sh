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

# ── Pre-pull base models (CPU-only, always available) ──────────
# @trace spec:inference-container
echo "[inference] Pulling base models..."
ollama pull qwen2.5:0.5b &
PULL_T0=$!
ollama pull tinyllama:1.1b &
PULL_T1=$!
wait $PULL_T0 2>/dev/null && echo "[inference] T0 (qwen2.5:0.5b) ready" || echo "[inference] T0 pull failed" >&2
wait $PULL_T1 2>/dev/null && echo "[inference] T1 (tinyllama:1.1b) ready" || echo "[inference] T1 pull failed" >&2
echo "[inference] Base models ready"

# ── Background: pull GPU-capable models if hardware supports ──
# @trace spec:inference-container
VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
VRAM_GB=$(( ${VRAM_MB:-0} / 1024 ))

if [ "$VRAM_GB" -ge 4 ]; then
    echo "[inference] GPU detected (${VRAM_GB}GB VRAM) — pulling GPU-tier models in background..."
    (
        ollama pull phi3.5:3.8b && echo "[inference] T2 (phi3.5:3.8b) ready" || echo "[inference] T2 pull failed" >&2
        if [ "$VRAM_GB" -ge 6 ]; then
            ollama pull qwen2.5-coder:7b && echo "[inference] T3 (qwen2.5-coder:7b) ready" || echo "[inference] T3 pull failed" >&2
        fi
        if [ "$VRAM_GB" -ge 8 ]; then
            ollama pull llama3.2:8b && echo "[inference] T4 (llama3.2:8b) ready" || echo "[inference] T4 pull failed" >&2
        fi
        if [ "$VRAM_GB" -ge 12 ]; then
            ollama pull qwen2.5:13b && echo "[inference] T5 (qwen2.5:13b) ready" || echo "[inference] T5 pull failed" >&2
        fi
        echo "[inference] GPU-tier model pulls complete"
    ) &
else
    echo "[inference] No GPU or <4GB VRAM — skipping GPU-tier models"
fi

# Hand off to ollama as the foreground process for signal handling.
wait $OLLAMA_PID
