#!/usr/bin/env bash
# @trace spec:web-image, spec:user-runtime-lifecycle, spec:litmus-framework
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'
_info()  { echo -e "${GREEN}[build-web]${NC} $*"; }
_step()  { echo -e "${CYAN}[build-web]${NC} $*"; }
_error() { echo -e "${RED}[build-web]${NC} $*" >&2; }
_step "Building web image via cargo run (litmus test)..."
if ! podman ps &>/dev/null; then
    _info "Podman state corrupted, resetting..."
    podman system reset --force 2>/dev/null || true
    sleep 1
fi
cd "$ROOT"
if ! toolbox run cargo run --bin build-image -- web "$@" 2>&1 | tee /tmp/build-web.log; then
    _error "Build failed"
    tail -20 /tmp/build-web.log >&2
    exit 1
fi
if grep -q "ImageBuilder trait not yet integrated" /tmp/build-web.log; then
    _step "ImageBuilder not yet integrated, using direct podman build..."
    "$ROOT/scripts/build-image.sh" web || exit 1
fi
_info "Web image rebuilt successfully"
_info "Current image: $(podman images | grep tillandsias-web | head -1 | awk '{print $3}')"
exit 0
