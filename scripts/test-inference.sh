#!/usr/bin/env bash
# @trace spec:inference-container, spec:enclave-network
# Diagnostic script: Launch inference container in isolation
# Tests ollama startup, model availability, and inference health checks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
require_podman
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONTAINER_NAME="tillandsias-diagnostic-inference"
DEFAULT_VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
IMAGE="${1:-tillandsias-inference:v${DEFAULT_VERSION}}"

echo "[diagnostic] Starting inference container isolation test..."
echo "[diagnostic] Image: $IMAGE"
echo "[diagnostic] Container: $CONTAINER_NAME"

# Clean up any stale container
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
cleanup() {
  podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# Create model cache directory
MODEL_CACHE="$HOME/.cache/tillandsias/models"
mkdir -p "$MODEL_CACHE"

echo "[diagnostic] Launching container with model cache at: $MODEL_CACHE"
if ! podman run \
  --detach \
  --rm \
  --name "$CONTAINER_NAME" \
  --hostname inference \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --userns=keep-id \
  --env "OLLAMA_DEBUG=1" \
  --env "OLLAMA_KEEP_ALIVE=24h" \
  -v "$MODEL_CACHE:/home/ollama/.ollama/models:rw" \
  "$IMAGE" \
  /usr/bin/ollama serve >/tmp/tillandsias-test-inference.log 2>&1; then
  echo "[diagnostic] ERROR: failed to start inference container" >&2
  exit 1
fi

echo "[diagnostic] Waiting for container health..."
if ! podman wait --condition=healthy "$CONTAINER_NAME"; then
  echo "[diagnostic] ERROR: inference container failed health check" >&2
  podman logs "$CONTAINER_NAME" 2>&1 | tail -30
  exit 1
fi

echo "[diagnostic] Verifying /api/version inside the container..."
if ! podman exec "$CONTAINER_NAME" sh -lc 'curl -fsS http://127.0.0.1:11434/api/version >/dev/null'; then
  echo "[diagnostic] ERROR: inference API probe failed" >&2
  podman logs "$CONTAINER_NAME" 2>&1 | tail -30
  exit 1
fi

echo "[diagnostic] Inference container is healthy and serving /api/version"
