#!/usr/bin/env bash
# @trace spec:proxy-container, spec:enclave-network
# Diagnose proxy container startup issues

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[proxy-diag]${NC} $*"; }
log_error() { echo -e "${RED}[proxy-diag]${NC} $*" >&2; }
log_step() { echo -e "${CYAN}[proxy-diag]${NC} $*"; }

# Get latest proxy image
PROXY_IMAGE=$(podman images --format "{{.Repository}}:{{.Tag}}" | grep tillandsias-proxy | sort -V | tail -1)
if [ -z "$PROXY_IMAGE" ]; then
    log_error "No proxy image found. Run './scripts/build-image.sh proxy' first."
    exit 1
fi

log_step "Proxy image: $PROXY_IMAGE"

# Create temporary directory for CA certs
CERTS_DIR=$(mktemp -d)
trap "rm -rf $CERTS_DIR" EXIT

log_step "Generating self-signed CA certificates..."
openssl req -x509 -newkey rsa:2048 -keyout "$CERTS_DIR/intermediate.key" \
    -out "$CERTS_DIR/intermediate.crt" -days 30 -nodes \
    -subj "/CN=tillandsias-proxy" 2>&1 | grep -v "Generating\|Can't load"

# Make files world-readable AND world-executable to work with --userns=keep-id and container user mapping
chmod 644 "$CERTS_DIR/intermediate.crt" "$CERTS_DIR/intermediate.key"
chmod 755 "$CERTS_DIR"

log_info "Certificate files:"
ls -lah "$CERTS_DIR/"

# Also copy to /tmp in host so we can use /tmp/... paths (which will be more readable)
cp "$CERTS_DIR/intermediate.crt" /tmp/proxy-ca.crt
cp "$CERTS_DIR/intermediate.key" /tmp/proxy-ca.key
chmod 644 /tmp/proxy-ca.*
log_info "Also copied to /tmp/proxy-ca.{crt,key}"

# Create network if needed
ENCLAVE_NET="tillandsias-enclave"
if ! podman network exists "$ENCLAVE_NET" 2>/dev/null; then
    log_step "Creating network: $ENCLAVE_NET"
    podman network create --driver bridge --subnet "10.0.42.0/24" "$ENCLAVE_NET"
fi

# Clean up old container
CONTAINER="test-proxy-$$"
podman rm -f "$CONTAINER" 2>/dev/null || true

log_step "Launching proxy container: $CONTAINER"
log_step "CA cert dir: $CERTS_DIR"

podman run \
    --interactive \
    --tty \
    --rm \
    --name "$CONTAINER" \
    --hostname proxy \
    --network "$ENCLAVE_NET" \
    --ip "10.0.42.2" \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --userns=keep-id \
    --pids-limit=32 \
    --read-only \
    --tmpfs=/tmp \
    --tmpfs=/var/run \
    --tmpfs=/var/spool/squid \
    --tmpfs=/var/lib/squid \
    -v "$CERTS_DIR/intermediate.crt:/etc/squid/certs/intermediate.crt:ro" \
    -v "$CERTS_DIR/intermediate.key:/etc/squid/certs/intermediate.key:ro" \
    "$PROXY_IMAGE"

log_info "Proxy diagnostic complete"
