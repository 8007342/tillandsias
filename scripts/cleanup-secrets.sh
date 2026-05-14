#!/usr/bin/env bash
# Remove all ephemeral podman secrets created by Tillandsias.
#
# This script removes all secrets that were created by the tray during
# initialization. It is called during graceful shutdown to clean up.
#
# Usage: scripts/cleanup-secrets.sh
#
# Exit codes:
#   0 = all secrets removed successfully (or already absent)
#   1 = podman unavailable
#
# @trace spec:secrets-management, spec:podman-secrets-integration, spec:secret-rotation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
require_podman

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[cleanup-secrets]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[cleanup-secrets]${NC} $*"; }
_error() { echo -e "${RED}[cleanup-secrets]${NC} $*" >&2; }
_step()  { echo -e "${CYAN}[cleanup-secrets]${NC} $*"; }

# Argument parsing (must be before podman check for --help to work)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: scripts/cleanup-secrets.sh"
            echo ""
            echo "Remove all ephemeral podman secrets created by Tillandsias."
            echo ""
            echo "Options:"
            echo "  --help   Show this message"
            exit 0
            ;;
        *)
            _error "Unknown argument: $1 (try --help)"
            exit 1
            ;;
    esac
    shift
done

_step "Removing ephemeral podman secrets..."

# List of secrets to remove
# @trace spec:podman-secrets-integration
SECRETS=(
    "tillandsias-ca-cert"
    "tillandsias-github-token"
)

REMOVED_COUNT=0
FAILED_COUNT=0

for secret in "${SECRETS[@]}"; do
    # Check if secret exists
    if "$PODMAN" secret inspect "$secret" &>/dev/null; then
        if "$PODMAN" secret rm "$secret" 2>/dev/null; then
            _info "  Removed secret: $secret"
            ((REMOVED_COUNT++))
        else
            _error "Failed to remove secret: $secret"
            ((FAILED_COUNT++))
        fi
    else
        # Secret doesn't exist (already removed or was never created)
        _info "  Secret not found (already removed): $secret"
    fi
done

if [[ $FAILED_COUNT -eq 0 ]]; then
    _info "All secrets cleaned up successfully ($REMOVED_COUNT removed)"
    exit 0
else
    _error "Failed to remove $FAILED_COUNT secret(s)"
    exit 1
fi
