#!/usr/bin/env bash
# @trace spec:user-runtime-lifecycle, spec:litmus-framework
# Rebuild all container images using quick-start litmus tests.
# This exercises the exact ImageBuilder code paths that tillandsias app uses.
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

IMAGES=("git" "proxy" "forge" "inference" "web")

if [[ "$PARALLEL" == "--parallel" ]]; then
    _step "Building in parallel..."
    for image in "${IMAGES[@]}"; do
        _info "  Starting $image..."
        "$ROOT/build-${image}.sh" &
    done
    wait
    _info "All builds completed"
else
    _step "Building sequentially..."
    for image in "${IMAGES[@]}"; do
        _step "Building $image..."
        "$ROOT/build-${image}.sh" || {
            echo "❌ Failed to build $image"
            exit 1
        }
    done
fi

_step "All images built successfully!"
_info "Run: killall tillandsias && tillandsias /path/to/project"
_info "Or: podman system prune -a  # Clean up old images"

exit 0
