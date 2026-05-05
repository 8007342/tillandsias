#!/usr/bin/env bash
# @trace spec:git-mirror-service, spec:user-runtime-lifecycle, spec:litmus-framework
# Quick-start litmus test: rebuild git image using prod code path.
#
# Usage:
#   ./build-git.sh              # Rebuild git image (test mode)
#   ./build-git.sh --assert     # Rebuild + assert exact podman calls
#
# This exercises the exact ImageBuilder code that tillandsias app uses.
# When ready, tilmandsias will pick up the rebuilt tillandsias-git:vX.Y.Z
#
# Pattern:
#   ./build-git.sh && podman restart $(podman ps -a --filter name=tillandsias-git -q)
# Or just restart the tillandsias binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[build-git]${NC} $*"; }
_step()  { echo -e "${CYAN}[build-git]${NC} $*"; }
_error() { echo -e "${RED}[build-git]${NC} $*" >&2; }

_step "Building git image via cargo run (litmus test)..."


# Exercise prod code path (when ImageBuilder integrated)
cd "$ROOT"
if ! toolbox run cargo run --bin build-image -- git "$@" 2>&1 | tee /tmp/build-git.log; then
    _error "Build failed"
    tail -20 /tmp/build-git.log >&2
    exit 1
fi

if grep -q "ImageBuilder trait not yet integrated" /tmp/build-git.log; then
    _step "ImageBuilder not yet integrated, using direct podman build..."

    # Fallback: direct podman build using refactored scripts
    "$ROOT/scripts/build-image.sh" git || exit 1
fi

_info "Git image rebuilt successfully"
_info "Current image: $(podman images | grep tillandsias-git | head -1 | awk '{print $3}')"
_info "Next step: restart tilmandsias binary or containers to pick up new image"

exit 0
