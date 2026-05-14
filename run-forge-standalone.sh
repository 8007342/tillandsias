#!/usr/bin/env bash
# @trace spec:forge-standalone, spec:default-image
# @cheatsheet runtime/forge-standalone.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"

if [[ -z "${TILLANDSIAS_PODMAN_REMOTE_URL:-}" ]]; then
    runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    remote_socket="$runtime_dir/podman/podman.sock"
    if [[ -S "$remote_socket" ]]; then
        export TILLANDSIAS_PODMAN_REMOTE_URL="unix://$remote_socket"
    fi
fi

source "$SCRIPT_DIR/scripts/common.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[run-forge-standalone]${NC} $*"; }
_step()  { echo -e "${CYAN}[run-forge-standalone]${NC} $*"; }
_error() { echo -e "${RED}[run-forge-standalone]${NC} $*" >&2; }

_banner() {
    echo -e "${CYAN}╭──────────────────────────────────────────────╮${NC}"
    echo -e "${CYAN}│${NC}  standalone forge shell                     ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  isolated podman container for local work   ${CYAN}│${NC}"
    echo -e "${CYAN}╰──────────────────────────────────────────────╯${NC}"
}

usage() {
    cat <<'EOF'
Usage: ./run-forge-standalone.sh --src <path>

Launch a single standalone forge container from the forge image.

The script mounts the provided source directory at
/home/forge/src/<basename>, bypasses the default agent entrypoint, and
drops you into an interactive bash session for local inspection.
EOF
}

SRC_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)
            shift
            SRC_PATH="${1:-}"
            ;;
        --src=*)
            SRC_PATH="${1#*=}"
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

if [[ -z "$SRC_PATH" ]]; then
    _error "--src is required"
    usage >&2
    exit 2
fi

if [[ ! -e "$SRC_PATH" ]]; then
    _error "Source path does not exist: $SRC_PATH"
    exit 2
fi

if [[ ! -d "$SRC_PATH" ]]; then
    _error "Source path must be a directory: $SRC_PATH"
    exit 2
fi

if command -v realpath >/dev/null 2>&1; then
    HOST_SRC="$(realpath "$SRC_PATH")"
else
    SRC_DIR="$(cd "$(dirname "$SRC_PATH")" && pwd -P)"
    SRC_BASE="$(basename "$SRC_PATH")"
    HOST_SRC="${SRC_DIR}/${SRC_BASE}"
fi

PROJECT_NAME="$(basename "${HOST_SRC%/}")"
if [[ -z "$PROJECT_NAME" || "$PROJECT_NAME" == "." || "$PROJECT_NAME" == "/" ]]; then
    _error "Unable to derive a project name from: $HOST_SRC"
    exit 2
fi

CONTAINER_SRC="/home/forge/src/$PROJECT_NAME"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
if [[ -z "$VERSION" ]]; then
    _error "VERSION file is empty"
    exit 1
fi

IMAGE=""
for candidate in \
    "tillandsias-forge:v${VERSION}" \
    "localhost/tillandsias-forge:v${VERSION}"; do
    if podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Fxq "$candidate"; then
        IMAGE="$candidate"
        break
    fi
done

if [[ -z "$IMAGE" ]]; then
    _error "No local forge image found"
    _error "Build one first with ./build-forge.sh or scripts/build-image.sh forge"
    exit 1
fi

_step "Launching standalone forge bash session"
_banner
_info "Image:   $IMAGE"
_info "Mount:   $HOST_SRC -> $CONTAINER_SRC"
_info "Mode:    isolated forge container, default agent entrypoint bypassed"

exec podman run \
    --rm \
    --interactive \
    --tty \
    --name "tillandsias-forge-standalone-${PROJECT_NAME//[^[:alnum:]._-]/-}" \
    --hostname forge \
    --network=host \
    --userns=keep-id \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --security-opt=label=disable \
    --env HOME=/home/forge \
    --env USER=forge \
    --env PATH=/usr/local/bin:/usr/bin:/bin \
    --workdir "$CONTAINER_SRC" \
    --volume "$HOST_SRC:$CONTAINER_SRC:rw" \
    --entrypoint /bin/bash \
    "$IMAGE"
