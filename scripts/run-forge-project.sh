#!/usr/bin/env bash
# @trace spec:browser-isolation-tray-integration, spec:transparent-https-caching
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
Usage: scripts/run-forge-project.sh <project-path> [kind] [--recreate]

Launch a single forge project container directly so tray launch failures can
be reproduced without the tray UI in the loop.

Arguments:
  project-path  Host path to the project checkout to mirror into the container
  kind          One of: opencode, opencode-web, claude, terminal

Options:
  --recreate    Remove any existing repro container before starting
EOF
    exit 0
fi

PROJECT_PATH="${1:?'Usage: scripts/run-forge-project.sh <project-path> [kind] [--recreate]'}"
KIND="${2:-opencode}"
RECREATE=0

if [[ "$KIND" == "--recreate" ]]; then
    RECREATE=1
    KIND="opencode"
fi
if [[ "${3:-}" == "--recreate" ]]; then
    RECREATE=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
require_podman
PODMAN_CTL="$SCRIPT_DIR/tillandsias-podman"

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
PROJECT_ABS="$(cd "$PROJECT_PATH" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_ABS")"
IMAGE="${FORGE_IMAGE:-tillandsias-forge:v${VERSION}}"
CONTAINER_NAME="${FORGE_REPRO_CONTAINER_NAME:-tillandsias-repro-${PROJECT_NAME}-${KIND}}"
ENTRYPOINT="/usr/local/bin/entrypoint-forge-${KIND}.sh"
CERTS_DIR="${FORGE_REPRO_CERTS_DIR:-/tmp/tillandsias-ca}"
CA_CERT="${CERTS_DIR}/intermediate.crt"
ENCLAVE_NET="${FORGE_REPRO_NETWORK:-tillandsias-enclave}"
ENCLAVE_SUBNET="${FORGE_REPRO_SUBNET:-10.0.42.0/24}"
MIRROR_DIR="${FORGE_REPRO_MIRROR_DIR:-/mirror}"

case "$KIND" in
    opencode|opencode-web|claude|terminal) ;;
    *)
        echo "error: unsupported kind '$KIND' (use opencode, opencode-web, claude, or terminal)" >&2
        exit 2
        ;;
esac

if [[ "$RECREATE" -eq 1 ]]; then
    "$PODMAN_CTL" container rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

if ! "$PODMAN_CTL" network exists "$ENCLAVE_NET" >/dev/null 2>&1; then
    echo "[run-forge-project] Creating enclave network: $ENCLAVE_NET"
    "$PODMAN_CTL" network create --driver bridge --subnet "$ENCLAVE_SUBNET" "$ENCLAVE_NET" >/dev/null
fi

mkdir -p "$CERTS_DIR"
if [[ ! -f "$CA_CERT" ]]; then
    echo "[run-forge-project] Generating ephemeral CA: $CA_CERT"
    openssl req -x509 -newkey rsa:2048 -keyout "${CERTS_DIR}/intermediate.key" \
        -out "$CA_CERT" -days 30 -nodes \
        -subj "/C=US/ST=Privacy/L=Local/O=Tillandsias/CN=Tillandsias CA" >/dev/null 2>&1
    chmod 644 "$CA_CERT" 2>/dev/null || true
    chmod 600 "${CERTS_DIR}/intermediate.key" 2>/dev/null || true
fi

if "$PODMAN_CTL" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    echo "[run-forge-project] Reusing existing container: $CONTAINER_NAME"
else
    echo "[run-forge-project] Creating container: $CONTAINER_NAME"
    if ! "$PODMAN_CTL" container run \
        --detach \
        --rm \
        --name "$CONTAINER_NAME" \
        --label "app=tillandsias" \
        --label "role=forge-repro" \
        --userns=keep-id \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --security-opt=label=disable \
        --read-only \
        --tmpfs /tmp:rw,size=64m \
        --tmpfs /var/cache:rw,size=16m \
        --network "$ENCLAVE_NET" \
        --volume "${PROJECT_ABS}:${MIRROR_DIR}:ro" \
        --workdir /home/forge \
        --env HOME=/home/forge \
        --env USER=forge \
        --env PROJECT="$PROJECT_NAME" \
        --env TILLANDSIAS_PROJECT="$PROJECT_NAME" \
        --env TILLANDSIAS_GIT_MIRROR_PATH="$MIRROR_DIR" \
        --env http_proxy=http://proxy:3128 \
        --env https_proxy=http://proxy:3128 \
        --env HTTP_PROXY=http://proxy:3128 \
        --env HTTPS_PROXY=http://proxy:3128 \
        --env no_proxy=localhost,127.0.0.1,proxy,git-service,inference \
        --env NO_PROXY=localhost,127.0.0.1,proxy,git-service,inference \
        --env PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin \
        --volume "${CA_CERT}:/etc/tillandsias/ca.crt:ro" \
        --entrypoint "$ENTRYPOINT" \
        "$IMAGE" >/dev/null; then
        exit 1
    fi
fi

if ! "$PODMAN_CTL" container inspect "$CONTAINER_NAME" 2>/dev/null | grep -q '"state":"running"'; then
    echo "[run-forge-project] Starting container: $CONTAINER_NAME"
    "$PODMAN_CTL" container start "$CONTAINER_NAME" >/dev/null
fi

echo "[run-forge-project] Logs for container: $CONTAINER_NAME"
"$PODMAN_CTL" container logs "$CONTAINER_NAME" 50
