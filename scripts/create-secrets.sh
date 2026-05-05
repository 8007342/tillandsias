#!/usr/bin/env bash
# Create and manage ephemeral podman secrets for Tillandsias containers.
#
# This script creates secrets used by the enclave to pass credentials to
# containers at runtime. Secrets are ephemeral and removed when the tray exits.
#
# Usage: scripts/create-secrets.sh [--github-token <token>]
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
        --help|-h)
            echo "Usage: scripts/create-secrets.sh [--github-token <token>]"
            echo ""
            echo "Create ephemeral podman secrets for Tillandsias containers."
            echo ""
            echo "Options:"
            echo "  --github-token <token>  GitHub OAuth token (optional, reads from keyring if not provided)"
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

# Generate a self-signed CA certificate if one doesn't exist locally.
# This certificate is used by the proxy container to perform SSL bumping.
# @trace spec:secrets-management, spec:proxy-container
CA_CERT_FILE="${HOME}/.cache/tillandsias/ca-cert.pem"
CA_KEY_FILE="${HOME}/.cache/tillandsias/ca-key.pem"

mkdir -p "$(dirname "$CA_CERT_FILE")"

# Only generate if not already present
if [[ ! -f "$CA_CERT_FILE" ]] || [[ ! -f "$CA_KEY_FILE" ]]; then
    _info "Generating self-signed CA certificate..."

    # Generate private key and self-signed certificate valid for 10 years
    openssl req -new -newkey rsa:2048 -days 3650 -nodes \
        -x509 -keyout "$CA_KEY_FILE" -out "$CA_CERT_FILE" \
        -subj "/C=US/ST=Privacy/L=Local/O=Tillandsias/CN=Tillandsias CA" 2>/dev/null || {
        _error "Failed to generate CA certificate (openssl not available)"
        exit 1
    }

    chmod 0600 "$CA_CERT_FILE" "$CA_KEY_FILE"
    _info "  CA certificate: $CA_CERT_FILE"
    _info "  CA private key: $CA_KEY_FILE"
else
    _info "Using existing CA certificate at $CA_CERT_FILE"
fi

# Create CA certificate secret in podman
_info "Creating CA certificate podman secret..."
SECRET_CA=$(mktemp)
cat "$CA_CERT_FILE" > "$SECRET_CA"
cat "$CA_KEY_FILE" >> "$SECRET_CA"

# Remove old CA secret if it exists (idempotent)
"$PODMAN" secret rm tillandsias-ca-cert 2>/dev/null || true

# Create the new secret
if "$PODMAN" secret create \
    --driver=file \
    tillandsias-ca-cert \
    "$SECRET_CA" 2>/dev/null; then
    _info "  CA certificate secret created: tillandsias-ca-cert"
    echo "tillandsias-ca-cert"
else
    _error "Failed to create CA certificate secret"
    rm -f "$SECRET_CA"
    exit 1
fi

rm -f "$SECRET_CA"

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
    "$PODMAN" secret rm tillandsias-github-token 2>/dev/null || true

    # Create the new secret
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
