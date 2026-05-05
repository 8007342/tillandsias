#!/usr/bin/env bash
# @trace spec:proxy-container, spec:user-runtime-lifecycle, spec:litmus-framework
# Quick-start litmus test: rebuild proxy image using prod code path.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'
_info()  { echo -e "${GREEN}[build-proxy]${NC} $*"; }
_step()  { echo -e "${CYAN}[build-proxy]${NC} $*"; }
_error() { echo -e "${RED}[build-proxy]${NC} $*" >&2; }
_step "Building proxy image via cargo run (litmus test)..."
cd "$ROOT"
if ! toolbox run cargo run --bin build-image -- proxy "$@" 2>&1 | tee /tmp/build-proxy.log; then
    _error "Build failed"
    tail -20 /tmp/build-proxy.log >&2
    exit 1
fi
if grep -q "ImageBuilder trait not yet integrated" /tmp/build-proxy.log; then
    _step "ImageBuilder not yet integrated, using direct podman build..."
    "$ROOT/scripts/build-image.sh" proxy || exit 1
fi
_info "Proxy image rebuilt successfully"
_info "Current image: $(podman images | grep tillandsias-proxy | head -1 | awk '{print $3}')"
exit 0
