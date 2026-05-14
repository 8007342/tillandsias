#!/usr/bin/env bash
# @trace spec:default-image, spec:user-runtime-lifecycle, spec:litmus-framework, spec:forge-standalone
# Quick-start litmus test: rebuild forge image using the direct image builder.
#
# Host-level orchestrator: keeps the user runtime path separate from any
# development toolchain wrapper and delegates to the source-of-truth image
# builder directly.
#
# Usage:
#   ./build-forge.sh              # Rebuild forge image
#   ./build-forge.sh --assert     # Rebuild + assert a forge image exists
#   ./build-forge.sh --force      # Force rebuild even if sources are fresh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[build-forge]${NC} $*"; }
_step()  { echo -e "${CYAN}[build-forge]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[build-forge]${NC} $*"; }
_error() { echo -e "${RED}[build-forge]${NC} $*" >&2; }

FLAG_ASSERT=false
FLAG_FORCE=false
FLAG_TAG=""

usage() {
    cat <<'EOF'
Usage: ./build-forge.sh [--assert] [--force] [--tag <tag>]

Rebuild the forge image by delegating to scripts/build-image.sh forge.

Flags:
  --assert        Verify a forge image tag exists after the build
  --force         Force a rebuild even when the source hash matches
  --tag <tag>     Override the canonical image tag
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --assert)
            FLAG_ASSERT=true
            ;;
        --force)
            FLAG_FORCE=true
            ;;
        --tag)
            shift
            FLAG_TAG="${1:-}"
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            _error "Unknown argument: $1"
            usage >&2
            exit 1
            ;;
    esac
    shift
done

build_args=(forge)
if [[ "$FLAG_FORCE" == true ]]; then
    build_args+=(--force)
fi
if [[ -n "$FLAG_TAG" ]]; then
    build_args+=(--tag "$FLAG_TAG")
fi

if [[ -z "${TILLANDSIAS_PODMAN_REMOTE_URL:-}" ]]; then
    runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    remote_socket="$runtime_dir/podman/podman.sock"
    if [[ -S "$remote_socket" ]]; then
        if podman --remote --url "unix://$remote_socket" info >/dev/null 2>&1; then
            export TILLANDSIAS_PODMAN_REMOTE_URL="unix://$remote_socket"
            _step "Using Podman remote socket: $TILLANDSIAS_PODMAN_REMOTE_URL"
        else
            _warn "Podman socket exists but is not reachable from this session; falling back to local Podman"
        fi
    fi
fi

_step "Building forge image via scripts/build-image.sh forge..."
if ! "$ROOT/scripts/build-image.sh" "${build_args[@]}"; then
    _error "Forge image build failed"
    exit 1
fi

if [[ "$FLAG_ASSERT" == true ]]; then
    _step "Asserting forge image exists after build..."
    if ! podman images --format '{{.Repository}}:{{.Tag}}' | grep -Eq '^(localhost/)?tillandsias-forge:'; then
        _error "Forge image assertion failed"
        exit 1
    fi
fi

_info "Forge image rebuilt successfully"
_info "Current forge image tags:"
podman images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -E '^(localhost/)?tillandsias-forge:' | head -n 5 || true
_info "Next step: restart tillandsias binary or containers to pick up new image"

exit 0
