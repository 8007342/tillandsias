#!/usr/bin/env bash
# @trace spec:default-image, spec:user-runtime-lifecycle, spec:litmus-framework
# Quick-start litmus test: rebuild forge image using prod code path.
#
# Host-level orchestrator: separates dev environment (cargo/toolbox) from
# user runtime (podman on host).
#
# Usage:
#   ./build-forge.sh              # Rebuild forge image (test mode)
#   ./build-forge.sh --assert     # Rebuild + assert exact podman calls

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"
TOOLBOX_NAME="$(basename "$ROOT")"
TMP_BUILD_LOG="/tmp/build-forge.log"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[build-forge]${NC} $*"; }
_step()  { echo -e "${CYAN}[build-forge]${NC} $*"; }
_error() { echo -e "${RED}[build-forge]${NC} $*" >&2; }

trap '_error "Interrupted"; exit 130' SIGTERM SIGINT

_step "Building forge image (host-level orchestrator)..."

# Step 1: Run cargo inside dev environment (toolbox)
_step "Preparing image metadata via cargo..."
if ! toolbox -c "$TOOLBOX_NAME" run cargo run --bin build-image -- forge "$@" 2>&1 | tee "$TMP_BUILD_LOG"; then
    _error "Cargo prepare failed"
    tail -20 "$TMP_BUILD_LOG" >&2
    exit 1
fi

# Step 2: Check if ImageBuilder is integrated
if grep -q "ImageBuilder trait not yet integrated" "$TMP_BUILD_LOG"; then
    _step "ImageBuilder not integrated; using direct podman build (host)..."
    "$ROOT/scripts/build-image.sh" forge || exit 1
else
    _step "ImageBuilder integrated; executing via PodmanExecutor..."
fi

_info "Forge image rebuilt successfully"
_info "Current image: $(podman images | grep tillandsias-forge | head -1 | awk '{print $3}')"
_info "Next step: restart tillandsias binary or containers to pick up new image"

exit 0
