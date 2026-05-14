#!/usr/bin/env bash
# @trace spec:enclave-network, spec:simplified-tray-ux
# Diagnostic script: Launch git-mirror container in isolation
# Tests GitHub reachability and git credential flow

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
require_podman
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONTAINER_NAME="tillandsias-diagnostic-git"
DEFAULT_VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
IMAGE="${1:-tillandsias-git:v${DEFAULT_VERSION}}"

echo "[diagnostic] Starting git-mirror container isolation test..."
echo "[diagnostic] Image: $IMAGE"
echo "[diagnostic] Container: $CONTAINER_NAME"

# Clean up any stale container
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Launch git mirror with diagnostic logging
echo "[diagnostic] Launching container..."
podman run \
  --rm \
  --interactive \
  --tty \
  --name "$CONTAINER_NAME" \
  --hostname git-mirror \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --userns=keep-id \
  --env "DEBUG_GIT=1" \
  --env "GIT_TRACE=1" \
  "$IMAGE" \
  /bin/bash

echo "[diagnostic] Git mirror container exited"
