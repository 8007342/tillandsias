#!/usr/bin/env bash
# @trace spec:default-image, spec:user-runtime-lifecycle, spec:litmus-framework
# Quick-start litmus test: rebuild forge image using prod code path.
#
# Usage:
#   ./build-forge.sh              # Rebuild forge image (test mode)
#   ./build-forge.sh --assert     # Rebuild + assert exact podman calls
#
# This exercises the exact ImageBuilder code that tillandsias app uses.
# When ready, tillandsias will pick up the rebuilt tillandsias-forge:vX.Y.Z

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[build-forge]${NC} $*"; }
_step()  { echo -e "${CYAN}[build-forge]${NC} $*"; }
_error() { echo -e "${RED}[build-forge]${NC} $*" >&2; }

_step "Building forge image via cargo run (litmus test)..."

# Reset podman state if corrupted (ephemeral principle)
if ! podman ps &>/dev/null; then
    _info "Podman state corrupted, resetting..."
    podman system reset --force 2>/dev/null || true
    sleep 1
fi

# Exercise prod code path (when ImageBuilder integrated)
cd "$ROOT"
if ! toolbox run cargo run --bin build-image -- forge "$@" 2>&1 | tee /tmp/build-forge.log; then
    _error "Build failed"
    tail -20 /tmp/build-forge.log >&2
    exit 1
fi

if grep -q "ImageBuilder trait not yet integrated" /tmp/build-forge.log; then
    _step "ImageBuilder not yet integrated, using direct podman build..."

    # Fallback: direct podman build using refactored scripts
    "$ROOT/scripts/build-image.sh" forge || exit 1
fi

_info "Forge image rebuilt successfully"
_info "Current image: $(podman images | grep tillandsias-forge | head -1 | awk '{print $3}')"
_info "Next step: restart tilmandsias binary or containers to pick up new image"

exit 0
