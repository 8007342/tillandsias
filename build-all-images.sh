#!/usr/bin/env bash
# @trace spec:user-runtime-lifecycle, spec:litmus-framework
# Build the complete local image matrix through the canonical build engine.
#
# Usage:
#   ./build-all-images.sh           # Rebuild all (sequential)
#   ./build-all-images.sh --parallel # Rebuild all (parallel, faster)
#
# After rebuild, restart tilmandsias binary to pick up new images:
#   killall tillandsias
#   tillandsias /path/to/project
#
# Or restart individual containers:
#   podman restart tillandsias-git-*
#   podman restart tillandsias-proxy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"
PARALLEL="${1:---sequential}"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[build-all]${NC} $*"; }
_step()  { echo -e "${CYAN}[build-all]${NC} $*"; }

_step "Building all container images (mode: $PARALLEL)..."

IMAGES=(
    proxy
    git
    inference
    router
    vault
    forge
    web
)

if [[ "$PARALLEL" == "--parallel" ]]; then
    _step "Building chromium-core before parallel dependents..."
    "$ROOT/scripts/build-image.sh" chromium-core

    _step "Building remaining images in parallel (storage mutations remain serialized)..."
    pids=()
    for image in "${IMAGES[@]}" chromium-framework; do
        _info "  Starting $image..."
        "$ROOT/scripts/build-image.sh" "$image" &
        pids+=("$!")
    done
    failed=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            failed=1
        fi
    done
    if [[ "$failed" -ne 0 ]]; then
        echo "❌ One or more image builds failed"
        exit 1
    fi
    _info "All builds completed"
else
    _step "Building sequentially..."
    for image in "${IMAGES[@]:0:4}" chromium-core chromium-framework "${IMAGES[@]:4}"; do
        _step "Building $image..."
        "$ROOT/scripts/build-image.sh" "$image" || {
            echo "❌ Failed to build $image"
            exit 1
        }
    done
fi

_step "All images built successfully!"
_info "Run: killall tillandsias && tillandsias /path/to/project"
_info "Or: podman system prune -a  # Clean up old images"

exit 0
