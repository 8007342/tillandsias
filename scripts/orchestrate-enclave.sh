#!/usr/bin/env bash
# @trace spec:enclave-network, spec:proxy-container, spec:git-mirror-service, spec:inference-container, spec:default-image
# Orchestrate the complete enclave stack with network setup and diagnostics
# Usage: ./scripts/orchestrate-enclave.sh <project-path> <project-name>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_PATH="${1:-.}"
PROJECT_NAME="${2:-$(basename "$PROJECT_PATH")}"
VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"

# @trace spec:enclave-network
ENCLAVE_NET="tillandsias-enclave"
ENCLAVE_SUBNET="10.0.42.0/24"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[orchestrate]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[orchestrate]${NC} $*"; }
log_error() { echo -e "${RED}[orchestrate]${NC} $*" >&2; }
log_step() { echo -e "${CYAN}[orchestrate]${NC} $*"; }

# ===========================================================================
# Step 1: Network Setup
# ===========================================================================
log_step "Setting up enclave network..."

# Check if network exists
if ! podman network exists "$ENCLAVE_NET" 2>/dev/null; then
    log_info "Creating network: $ENCLAVE_NET ($ENCLAVE_SUBNET)"
    podman network create \
        --driver bridge \
        --subnet "$ENCLAVE_SUBNET" \
        "$ENCLAVE_NET" || {
        log_error "Failed to create network"
        exit 1
    }
else
    log_info "Network already exists: $ENCLAVE_NET"
fi

# ===========================================================================
# Step 1b: Certificate Authority Generation
# ===========================================================================
# @trace spec:transparent-https-caching, spec:proxy-container
# Generate ephemeral 30-day CA cert for entire enclave stack.
# Stored at /tmp/tillandsias-ca/ so it persists across container restarts
# within a session, but is wiped on host reboot (ephemeral-first security).
log_step "Setting up transparent HTTPS certificate authority..."

CERTS_DIR="/tmp/tillandsias-ca"
mkdir -p "$CERTS_DIR"

# Idempotent: only generate if cert doesn't exist or is older than 25 days
if [ ! -f "$CERTS_DIR/intermediate.crt" ] || \
   [ $(find "$CERTS_DIR/intermediate.crt" -mtime +25 2>/dev/null | wc -l) -gt 0 ]; then
    log_info "Generating new 30-day CA certificate for enclave..."
    openssl req -x509 -newkey rsa:2048 -keyout "$CERTS_DIR/intermediate.key" \
        -out "$CERTS_DIR/intermediate.crt" -days 30 -nodes \
        -subj "/C=US/ST=Privacy/L=Local/O=Tillandsias/CN=Tillandsias CA" 2>/dev/null || {
        log_error "Failed to generate CA certificates"
        exit 1
    }
    chmod 644 "$CERTS_DIR/intermediate.crt"
    chmod 600 "$CERTS_DIR/intermediate.key"
    log_info "CA certificate generated: $CERTS_DIR/intermediate.crt (30 days)"
else
    log_info "Using existing CA certificate: $CERTS_DIR/intermediate.crt"
fi

# ===========================================================================
# Step 2: Proxy Container (critical path)
# ===========================================================================
log_step "Starting proxy container..."

PROXY_CONTAINER="tillandsias-proxy"
PROXY_IMAGE=$(podman images --format "{{.Repository}}:{{.Tag}}" | grep tillandsias-proxy | head -1)
if [ -z "$PROXY_IMAGE" ]; then
    log_error "Proxy image not found. Run './scripts/build-image.sh proxy' first."
    exit 1
fi

podman rm -f "$PROXY_CONTAINER" 2>/dev/null || true

if ! podman run \
    --detach \
    --rm \
    --name "$PROXY_CONTAINER" \
    --hostname proxy \
    --network "$ENCLAVE_NET" \
    --ip "10.0.42.2" \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --userns=keep-id \
    --pids-limit=32 \
    --read-only \
    --env "DEBUG_PROXY=1" \
    -v "$CERTS_DIR/intermediate.crt:/etc/squid/certs/intermediate.crt:ro" \
    -v "$CERTS_DIR/intermediate.key:/etc/squid/certs/intermediate.key:ro" \
    "$PROXY_IMAGE" 2>&1 | tee /tmp/proxy-start.log; then
    log_error "Failed to start proxy container"
    podman logs "$PROXY_CONTAINER" 2>&1 | tail -20
    exit 1
fi

log_info "Proxy container started: $PROXY_CONTAINER"

# Health check: wait for port 3128
log_step "Checking proxy health on :3128..."
for i in {1..15}; do
    if podman exec "$PROXY_CONTAINER" nc -zv 127.0.0.1 3128 &>/dev/null; then
        log_info "✓ Proxy responding on :3128 (attempt $i)"
        break
    fi
    if [ $i -eq 15 ]; then
        log_error "✗ Proxy not responding after 15 attempts"
        podman logs "$PROXY_CONTAINER" 2>&1 | tail -30
        exit 1
    fi
    sleep 1
done

# ===========================================================================
# Step 3: Git Mirror Container
# ===========================================================================
log_step "Starting git mirror container..."

GIT_CONTAINER="tillandsias-git-$PROJECT_NAME"
GIT_IMAGE=$(podman images --format "{{.Repository}}:{{.Tag}}" | grep "tillandsias-git" | grep -v framework | head -1)
if [ -z "$GIT_IMAGE" ]; then
    log_warn "Git image not found, skipping"
else
    podman rm -f "$GIT_CONTAINER" 2>/dev/null || true

    if ! podman run \
        --detach \
        --rm \
        --name "$GIT_CONTAINER" \
        --hostname "git-$PROJECT_NAME" \
        --network "$ENCLAVE_NET" \
        --ip "10.0.42.3" \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --userns=keep-id \
        --pids-limit=64 \
        --read-only \
        --env "PROJECT=$PROJECT_NAME" \
        --env "GIT_TRACE=1" \
        --mount "type=bind,source=$CERTS_DIR/intermediate.crt,target=/etc/tillandsias/ca.crt,readonly=true" \
        "$GIT_IMAGE" \
    /usr/bin/git daemon --verbose --listen=0.0.0.0 --base-path=/var/lib/git 2>&1 | tee /tmp/git-start.log; then
    log_error "Failed to start git mirror container"
    exit 1
fi

log_info "Git mirror container started: $GIT_CONTAINER"

# @trace spec:socket-container-orchestration
log_step "Waiting for git daemon readiness..."
if ! podman wait --condition=healthy "$GIT_CONTAINER"; then
    log_error "Git daemon '${GIT_CONTAINER}' failed health check"
    log_error "Image may be incomplete. Rebuild: scripts/build-image.sh git"
    exit 1
fi
log_info "✓ Git daemon ready"

# ===========================================================================
# Step 4: Inference Container (non-blocking)
# ===========================================================================
log_step "Starting inference container (non-blocking)..."

INFERENCE_CONTAINER="tillandsias-inference"
podman rm -f "$INFERENCE_CONTAINER" 2>/dev/null || true

podman run \
    --detach \
    --rm \
    --name "$INFERENCE_CONTAINER" \
    --hostname inference \
    --network "$ENCLAVE_NET" \
    --ip "10.0.42.4" \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --userns=keep-id \
    --pids-limit=128 \
    --env "OLLAMA_DEBUG=1" \
    --env "OLLAMA_KEEP_ALIVE=24h" \
    -v "$HOME/.cache/tillandsias/models:/root/.ollama/models:rw" \
    --mount "type=bind,source=$CERTS_DIR/intermediate.crt,target=/etc/tillandsias/ca.crt,readonly=true" \
    "tillandsias-inference:v${VERSION}" \
    /usr/bin/ollama serve &>/tmp/inference-start.log &

log_info "Inference container spawned (background)"

# ===========================================================================
# Step 5: Forge Container
# ===========================================================================
log_step "Starting forge container..."

FORGE_CONTAINER="tillandsias-$PROJECT_NAME-forge"
podman rm -f "$FORGE_CONTAINER" 2>/dev/null || true

if ! podman run \
    --interactive \
    --tty \
    --rm \
    --name "$FORGE_CONTAINER" \
    --hostname "forge-$PROJECT_NAME" \
    --network "$ENCLAVE_NET" \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --userns=keep-id \
    --pids-limit=512 \
    --env "http_proxy=http://proxy:3128" \
    --env "https_proxy=http://proxy:3128" \
    --env "HTTP_PROXY=http://proxy:3128" \
    --env "HTTPS_PROXY=http://proxy:3128" \
    --env "no_proxy=localhost,127.0.0.1,10.0.42.0/24" \
    --env "PATH=/usr/local/bin:/usr/bin" \
    --env "HOME=/home/forge" \
    --env "USER=forge" \
    --env "PROJECT=$PROJECT_NAME" \
    -v "$PROJECT_PATH:/home/forge/src:rw" \
    --mount "type=bind,source=$CERTS_DIR/intermediate.crt,target=/etc/tillandsias/ca.crt,readonly=true" \
    "tillandsias-forge:v${VERSION}" \
    /bin/bash; then
    log_error "Forge container exited with error"
    exit 1
fi

# ===========================================================================
# Cleanup
# ===========================================================================
log_step "Cleaning up containers..."
podman rm -f "$PROXY_CONTAINER" "$GIT_CONTAINER" "$INFERENCE_CONTAINER" 2>/dev/null || true

log_info "Orchestration complete"
