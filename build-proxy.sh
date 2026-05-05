#!/usr/bin/env bash
# @trace spec:proxy-container, spec:user-runtime-lifecycle, spec:litmus-framework
# Quick-start litmus test: rebuild proxy image using prod code path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"
TOOLBOX_NAME="$(basename "$ROOT")"
TMP_BUILD_LOG="/tmp/build-proxy.log"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[build-proxy]${NC} $*"; }
_step()  { echo -e "${CYAN}[build-proxy]${NC} $*"; }
_error() { echo -e "${RED}[build-proxy]${NC} $*" >&2; }

trap '_error "Interrupted"; exit 130' SIGTERM SIGINT

_step "Building proxy image (host-level orchestrator)..."

if ! toolbox -c "$TOOLBOX_NAME" run cargo run --bin build-image -- proxy "$@" 2>&1 | tee "$TMP_BUILD_LOG"; then
    _error "Cargo prepare failed"
    tail -20 "$TMP_BUILD_LOG" >&2
    exit 1
fi

if grep -q "ImageBuilder trait not yet integrated" "$TMP_BUILD_LOG"; then
    _step "ImageBuilder not integrated; using direct podman build (host)..."
    "$ROOT/scripts/build-image.sh" proxy || exit 1
else
    _step "ImageBuilder integrated; executing via PodmanExecutor..."
fi

_info "Proxy image rebuilt successfully"
_info "Current image: $(podman images | grep tillandsias-proxy | head -1 | awk '{print $3}')"
_info "Next step: restart tillandsias binary or containers to pick up new image"

exit 0
