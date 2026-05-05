#!/usr/bin/env bash
# @trace spec:inference-container, spec:user-runtime-lifecycle, spec:litmus-framework
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'
_info()  { echo -e "${GREEN}[build-inference]${NC} $*"; }
_step()  { echo -e "${CYAN}[build-inference]${NC} $*"; }
_error() { echo -e "${RED}[build-inference]${NC} $*" >&2; }
_step "Building inference image via cargo run (litmus test)..."
cd "$ROOT"
if ! toolbox run cargo run --bin build-image -- inference "$@" 2>&1 | tee /tmp/build-inference.log; then
    _error "Build failed"
    tail -20 /tmp/build-inference.log >&2
    exit 1
fi
if grep -q "ImageBuilder trait not yet integrated" /tmp/build-inference.log; then
    _step "ImageBuilder not yet integrated, using direct podman build..."
    "$ROOT/scripts/build-image.sh" inference || exit 1
fi
_info "Inference image rebuilt successfully"
_info "Current image: $(podman images | grep tillandsias-inference | head -1 | awk '{print $3}')"
exit 0
