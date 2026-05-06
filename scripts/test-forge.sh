#!/usr/bin/env bash
# @trace spec:default-image, spec:enclave-network
# Diagnostic script: Launch forge container in isolation
# Tests development environment, tool availability, and enclave connectivity

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONTAINER_NAME="tillandsias-diagnostic-forge"
DEFAULT_VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
IMAGE="${1:-tillandsias-forge:v${DEFAULT_VERSION}}"
WORK_DIR="${2:-.}"

echo "[diagnostic] Starting forge container isolation test..."
echo "[diagnostic] Image: $IMAGE"
echo "[diagnostic] Container: $CONTAINER_NAME"
echo "[diagnostic] Work dir: $WORK_DIR"

# Clean up any stale container
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Launch forge with diagnostic logging (ephemeral tmpdir)
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "[diagnostic] Launching container with tmpdir: $TMPDIR"
podman run \
  --rm \
  --interactive \
  --tty \
  --name "$CONTAINER_NAME" \
  --hostname forge \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --userns=keep-id \
  --env "DEBUG=1" \
  --env "PATH=/usr/local/bin:/usr/bin" \
  --env "HOME=/home/forge" \
  --env "USER=forge" \
  -v "$WORK_DIR:/home/forge/src:ro" \
  "$IMAGE" \
  /bin/bash

echo "[diagnostic] Forge container exited"
