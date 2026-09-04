#!/usr/bin/env bash
# ORDER 998-qrwu: the CA directory comes from the ONE declaration
# (images/default/ca-path.txt), never a literal — see scripts/lib-ca-path.sh.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-ca-path.sh"
# @trace spec:proxy-container, spec:enclave-network
# Diagnose proxy container startup issues

set -euo pipefail


# ORDER 799-tb7q — resolve `openssl` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has the CLI.
#
# UNLIKE jq, OPENSSL WRITES FILES. The conversion is only safe because the
# toolbox shares /tmp with the host bidirectionally — VERIFIED on lenovinha
# 2026-08-26: a file the host wrote to /tmp is readable inside the container and
# vice versa, and every CERTS_DIR here is under /tmp (mktemp -d, or
# ${TILLANDSIAS_CA_DIR}). A caller whose write path is NOT shared would have the
# cert land where the caller cannot find it — a silent break, not an error.
# Re-check the path before converting any further openssl site.
# shellcheck source=scripts/lib/tool-dispatch.sh
# Resolve the lib by WALKING UP, not by a fixed depth (order 914-ahsy). The
# fixed form `dirname "${BASH_SOURCE[0]}"/lib/...` is correct only for a caller
# sitting directly in scripts/. From scripts/refusal-calibration/ it points at a
# lib that does not exist, the `|| true` swallows the miss, and the tool variable
# silently falls back to the bare name — a conversion that passes review, passes
# the suite, and changes nothing.
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
if command -v resolve_tool >/dev/null 2>&1; then
    OPENSSL="$(resolve_tool openssl || printf 'openssl')"
else
    OPENSSL="openssl"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
require_podman

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
"$OPENSSL" req -x509 -newkey rsa:2048 -keyout "$CERTS_DIR/intermediate.key" \
    -out "$CERTS_DIR/intermediate.crt" -days 30 -nodes \
    -subj "/CN=tillandsias-proxy" 2>&1 | grep -v "Generating\|Can't load"

# The cert is public material; the PRIVATE key stays owner-only (755-qcxh) —
# the container receives it as a podman secret, not through file modes.
chmod 644 "$CERTS_DIR/intermediate.crt"
chmod 600 "$CERTS_DIR/intermediate.key"
chmod 755 "$CERTS_DIR"

log_info "Certificate files:"
ls -lah "$CERTS_DIR/"

# Also copy the PUBLIC cert to /tmp for convenient host-side inspection. The
# private key is never copied out or loosened (755-qcxh).
cp "$CERTS_DIR/intermediate.crt" /tmp/proxy-ca.crt
chmod 644 /tmp/proxy-ca.crt
log_info "Also copied to /tmp/proxy-ca.crt"

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

# 755-qcxh: deliver the CA private key as a podman secret (matches the
# entrypoint's only key path); the public cert stays a bind mount.
podman secret create --replace --driver=file tillandsias-ca-key "$CERTS_DIR/intermediate.key"

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
    --secret "tillandsias-ca-key,uid=1000,gid=1000,mode=0400" \
    "$PROXY_IMAGE"

log_info "Proxy diagnostic complete"
