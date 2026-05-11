#!/usr/bin/env bash
# @trace spec:forge-standalone-launcher
#
# Run a single forge container in isolation for hands-on tuning.
#
# This is a faithful reproduction of the security flags Tillandsias applies
# to production forge containers (see crates/tillandsias-podman/src/launch.rs),
# minus the enclave companions: no proxy, no git-service, no inference, no
# internal-only network. The forge gets the default rootless network so apt /
# cargo / nix / pip work directly. Useful for iterating on the forge image
# itself without booting the whole enclave.
#
# Usage:
#   ./run-forge-standalone.sh --src <path> [--create] [--detach] [--name <name>]
#
# Flags:
#   --src <path>     REQUIRED. Local host directory. Its basename becomes
#                    <project>, and the path is bind-mounted RW into the
#                    container at /home/forge/src/<project>.
#   --create         Build (or rebuild) the forge image via
#                    scripts/build-image.sh forge before launch. Without this
#                    flag no build is performed; if the image is missing the
#                    script exits with a clear hint.
#   --detach         Run detached with the image's normal entrypoint. Default
#                    is interactive: -it /bin/bash at the project workdir.
#   --name <name>    Container name. Default: tillandsias-standalone-<project>.
#
# Examples:
#   ./run-forge-standalone.sh --src ~/code/my-app
#   ./run-forge-standalone.sh --src ~/code/my-app --create
#   ./run-forge-standalone.sh --src ~/code/my-app --detach --name forge-poke

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"

SRC=""
CREATE=0
DETACH=0
NAME=""

usage() {
    sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)
            [[ $# -ge 2 ]] || { echo "error: --src requires a value" >&2; exit 2; }
            SRC="$2"; shift 2 ;;
        --src=*)   SRC="${1#--src=}"; shift ;;
        --create)  CREATE=1; shift ;;
        --detach)  DETACH=1; shift ;;
        --name)
            [[ $# -ge 2 ]] || { echo "error: --name requires a value" >&2; exit 2; }
            NAME="$2"; shift 2 ;;
        --name=*)  NAME="${1#--name=}"; shift ;;
        -h|--help) usage 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage 2 ;;
    esac
done

if [[ -z "$SRC" ]]; then
    echo "error: --src <path> is required" >&2
    usage 2
fi

if [[ ! -d "$SRC" ]]; then
    echo "error: --src path does not exist or is not a directory: $SRC" >&2
    exit 2
fi

SRC_ABS="$(cd "$SRC" && pwd)"
PROJECT="$(basename "$SRC_ABS")"
NAME="${NAME:-tillandsias-standalone-$PROJECT}"

if [[ ! -f "$ROOT/VERSION" ]]; then
    echo "error: VERSION file missing at $ROOT/VERSION" >&2
    exit 1
fi
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
IMAGE="tillandsias-forge:v$VERSION"

# --create => always (re)build; otherwise never build.
if [[ "$CREATE" -eq 1 ]]; then
    echo "[run-forge-standalone] --create set: building image $IMAGE"
    "$ROOT/scripts/build-image.sh" forge
else
    if ! podman image exists "$IMAGE"; then
        echo "error: image $IMAGE not found locally." >&2
        echo "  Re-run with --create to build it via scripts/build-image.sh forge." >&2
        exit 1
    fi
fi

# Tear down any stale container of the same name (idempotent relaunch).
if podman container exists "$NAME"; then
    echo "[run-forge-standalone] removing stale container: $NAME"
    podman rm -f "$NAME" >/dev/null
fi

MOUNT_DEST="/home/forge/src/$PROJECT"

echo "[run-forge-standalone] image     : $IMAGE"
echo "[run-forge-standalone] container : $NAME"
echo "[run-forge-standalone] mount     : $SRC_ABS -> $MOUNT_DEST (rw)"
echo "[run-forge-standalone] mode      : $( [[ $DETACH -eq 1 ]] && echo detached || echo 'interactive bash' )"

# Security flags mirror crates/tillandsias-podman/src/launch.rs:24-92 minus
# enclave network attachment, secrets, port range, and cache volumes.
COMMON_ARGS=(
    --rm
    --name "$NAME"
    --hostname forge
    --cap-drop=ALL
    --security-opt=no-new-privileges
    --security-opt=label=disable
    --userns=keep-id
    -v "$SRC_ABS:$MOUNT_DEST:rw"
    -w "$MOUNT_DEST"
)

if [[ "$DETACH" -eq 1 ]]; then
    podman run -d "${COMMON_ARGS[@]}" "$IMAGE"
    echo "[run-forge-standalone] enter the container with:"
    echo "    podman exec -it $NAME /bin/bash"
else
    exec podman run -it "${COMMON_ARGS[@]}" "$IMAGE" /bin/bash
fi
