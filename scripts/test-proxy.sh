#!/usr/bin/env bash
# @trace spec:enclave-network, spec:proxy-container
# Diagnostic script: Launch proxy container in isolation
# Tests domain allowlist, HTTPS caching, and upstreaming

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
require_podman
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONTAINER_NAME="tillandsias-diagnostic-proxy"
DEFAULT_VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
IMAGE="${1:-tillandsias-proxy:v${DEFAULT_VERSION}}"

echo "[diagnostic] Starting proxy container isolation test..."
echo "[diagnostic] Image: $IMAGE"
echo "[diagnostic] Container: $CONTAINER_NAME"

# Clean up any stale container
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Launch proxy with diagnostic logging
echo "[diagnostic] Launching container..."
podman run \
  --rm \
  --interactive \
  --tty \
  --name "$CONTAINER_NAME" \
  --hostname proxy \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --userns=keep-id \
  --env "DEBUG_PROXY=1" \
  --env "SQUID_DEBUG=all" \
  -p 127.0.0.1:3128:3128 \
  "$IMAGE" \
  /bin/bash

echo "[diagnostic] Proxy container exited"
