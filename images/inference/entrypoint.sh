#!/bin/bash
set -e
# @trace spec:inference-container
# Entrypoint for the Tillandsias inference container.
# Starts ollama listening on all interfaces so forge containers can reach it.

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

# Run ollama as PID 1 so it receives signals properly.
exec ollama serve
