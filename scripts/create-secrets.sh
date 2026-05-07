#!/usr/bin/env bash
# Create and manage ephemeral podman secrets for Tillandsias containers.
#
# This script creates secrets used by the enclave to pass credentials to
# containers at runtime. Secrets are ephemeral and removed when the tray exits.
#
# Usage: scripts/create-secrets.sh [--github-token <token>|--github-token-stdin]
#
# Environment:
#   GITHUB_TOKEN      GitHub OAuth token (optional, reads from keyring if not provided)
#   PODMAN_PATH       Path to podman binary (optional, auto-detected)
#
# Output:
#   Lists created secret IDs, one per line
#
# Exit codes:
#   0 = all secrets created successfully
#   1 = podman unavailable or secret creation failed
#
# @trace spec:secrets-management, spec:podman-secrets-integration, spec:gh-auth-script

set -euo pipefail

# Resolve the podman binary
if [[ -n "${PODMAN_PATH:-}" ]] && [[ -x "$PODMAN_PATH" ]]; then
    PODMAN="$PODMAN_PATH"
elif [[ -x /usr/bin/podman ]]; then
    PODMAN=/usr/bin/podman
elif [[ -x /usr/local/bin/podman ]]; then
    PODMAN=/usr/local/bin/podman
else
    PODMAN=podman
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[create-secrets]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[create-secrets]${NC} $*"; }
_error() { echo -e "${RED}[create-secrets]${NC} $*" >&2; }
_step()  { echo -e "${CYAN}[create-secrets]${NC} $*"; }

# Verify podman is available
if ! command -v "$PODMAN" &>/dev/null; then
    _error "podman not found at $PODMAN"
    exit 1
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
SKIP_TOKEN_READ=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --github-token)
            shift
            GITHUB_TOKEN="$1"
            SKIP_TOKEN_READ=true
            ;;
        --github-token-stdin)
            IFS= read -r GITHUB_TOKEN
            SKIP_TOKEN_READ=true
            ;;
        --help|-h)
            echo "Usage: scripts/create-secrets.sh [--github-token <token>|--github-token-stdin]"
            echo ""
            echo "Create ephemeral podman secrets for Tillandsias containers."
            echo ""
            echo "Options:"
            echo "  --github-token <token>  GitHub OAuth token (optional, reads from keyring if not provided)"
            echo "  --github-token-stdin    Read GitHub OAuth token from stdin"
            echo "  --help                  Show this message"
            exit 0
            ;;
        *)
            _error "Unknown argument: $1 (try --help)"
            exit 1
            ;;
    esac
    shift
done

_step "Creating ephemeral podman secrets..."

# ---------------------------------------------------------------------------
# Create CA certificate secret (always)
# ---------------------------------------------------------------------------

# @tombstone obsolete:cache-backed-ca-generation — Moved to ephemeral generation in ca.rs
# Deleted 2026-05-05 — CA certificates are now generated on proxy startup (ephemeral,
# tmpfs-based, no persistent cache). Safe to delete after 0.1.169.229.

# ---------------------------------------------------------------------------
# Create GitHub token secret (if available)
# ---------------------------------------------------------------------------

# If GITHUB_TOKEN not provided via argument, attempt to read from native keyring.
# @trace spec:secrets-management, spec:native-secrets-store
if [[ -z "$GITHUB_TOKEN" ]] && [[ "$SKIP_TOKEN_READ" == false ]]; then
    _info "Reading GitHub token from OS keyring..."

    # Try to use the native keyring via a simple keyring lookup command.
    # This is a fallback; the Rust code uses the `keyring` crate directly.
    # On systems with secret-tool (Secret Service):
    if command -v secret-tool &>/dev/null; then
        GITHUB_TOKEN=$(secret-tool lookup tillandsias github-oauth-token 2>/dev/null || true)
    # On macOS with security command:
    elif [[ "$(uname -s)" == "Darwin" ]] && command -v security &>/dev/null; then
        GITHUB_TOKEN=$(security find-generic-password -a "tillandsias" -s "github-oauth-token" -w 2>/dev/null || true)
    fi
fi

if [[ -n "$GITHUB_TOKEN" ]]; then
    _info "Creating GitHub token podman secret..."

    # Remove old GitHub token secret if it exists (idempotent)
    # @trace spec:ephemeral-secret-refresh
    "$PODMAN" secret rm tillandsias-github-token 2>/dev/null || true

    # Create the new secret
    # @trace spec:ephemeral-secret-refresh
    if echo "$GITHUB_TOKEN" | "$PODMAN" secret create \
        --driver=file \
        tillandsias-github-token \
        - 2>/dev/null; then
        _info "  GitHub token secret created: tillandsias-github-token"
        echo "tillandsias-github-token"
    else
        _error "Failed to create GitHub token secret"
        exit 1
    fi
else
    _warn "No GitHub token available (not in environment or keyring)"
    _info "  Skipping GitHub token secret creation"
    _info "  Run 'tillandsias --github-login' to authenticate with GitHub"
fi

_info "Secrets created successfully"
exit 0
