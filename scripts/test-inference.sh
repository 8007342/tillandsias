#!/usr/bin/env bash
# @trace spec:inference-container, spec:enclave-network
# Diagnostic script: Launch inference container in isolation
# Tests ollama startup, model availability, and inference health checks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONTAINER_NAME="tillandsias-diagnostic-inference"
DEFAULT_VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
IMAGE="${1:-tillandsias-inference:v${DEFAULT_VERSION}}"

echo "[diagnostic] Starting inference container isolation test..."
echo "[diagnostic] Image: $IMAGE"
echo "[diagnostic] Container: $CONTAINER_NAME"

# Clean up any stale container
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Create model cache directory
MODEL_CACHE="$HOME/.cache/tillandsias/models"
mkdir -p "$MODEL_CACHE"

echo "[diagnostic] Launching container with model cache at: $MODEL_CACHE"
podman run \
  --rm \
  --interactive \
  --tty \
  --name "$CONTAINER_NAME" \
  --hostname inference \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --userns=keep-id \
  --env "OLLAMA_DEBUG=1" \
  --env "OLLAMA_KEEP_ALIVE=24h" \
  -v "$MODEL_CACHE:/root/.ollama/models:rw" \
  "$IMAGE" \
  /bin/bash

echo "[diagnostic] Inference container exited"
