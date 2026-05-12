#!/usr/bin/env bash
# @trace spec:forge-standalone-launcher, spec:enclave-compose-migration
#
# Run a single forge container in isolation for hands-on tuning.
#
# Now wraps `podman-compose -f compose.yaml -f compose.local.yaml -p
# <proj>-local` (the local overlay strips proxy/git/inference and gives
# the forge external egress on the default rootless network). Pass
# --legacy to fall back to the direct `podman run` path that this
# script shipped with — useful when podman-compose is unavailable, or
# when iterating on container flags below the Compose abstraction.
#
# Both paths apply the same security flags: --cap-drop=ALL,
# --security-opt=no-new-privileges, --security-opt=label=disable,
# --userns=keep-id, --rm.
#
# Usage:
#   ./run-forge-standalone.sh --src <path> [--create] [--detach] [--name <name>] [--legacy]
#
# Flags:
#   --src <path>     REQUIRED. Local host directory. Its basename becomes
#                    <project>, and the path is bind-mounted RW into the
#                    container at /home/forge/src/<project>.
#   --create         Build (or rebuild) the forge image via
#                    scripts/build-image.sh forge before launch. Without this
#                    flag no build is performed; if the image is missing the
#                    script exits with a clear hint.
#   --detach         Run detached. Default is interactive: bash at the
#                    project workdir.
#   --name <name>    Container/project name suffix. Default:
#                    tillandsias-standalone-<project> (legacy) or
#                    tillandsias-<project>-local (compose).
#   --legacy         Use the direct `podman run` path instead of compose.
#                    Equivalent to this script's pre-migration behavior.
#
# Examples:
#   ./run-forge-standalone.sh --src ~/code/my-app
#   ./run-forge-standalone.sh --src ~/code/my-app --create
#   ./run-forge-standalone.sh --src ~/code/my-app --detach
#   ./run-forge-standalone.sh --src ~/code/my-app --legacy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"

SRC=""
CREATE=0
DETACH=0
NAME=""
LEGACY=0

usage() {
    sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
        --legacy)  LEGACY=1; shift ;;
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

if [[ ! -f "$ROOT/VERSION" ]]; then
    echo "error: VERSION file missing at $ROOT/VERSION" >&2
    exit 1
fi
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
IMAGE="tillandsias-forge:v$VERSION"

# --create => always (re)build via Nix pipeline.
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

# ── Legacy path: direct podman run, no compose dependency ──────────
if [[ "$LEGACY" -eq 1 ]]; then
    NAME="${NAME:-tillandsias-standalone-$PROJECT}"

    if podman container exists "$NAME"; then
        echo "[run-forge-standalone] removing stale container: $NAME"
        podman rm -f "$NAME" >/dev/null
    fi

    MOUNT_DEST="/home/forge/src/$PROJECT"
    echo "[run-forge-standalone] mode      : LEGACY (direct podman)"
    echo "[run-forge-standalone] image     : $IMAGE"
    echo "[run-forge-standalone] container : $NAME"
    echo "[run-forge-standalone] mount     : $SRC_ABS -> $MOUNT_DEST (rw)"

    # Mirrors crates/tillandsias-podman/src/launch.rs:24-92 minus enclave
    # network attachment, secrets, port range, and cache volumes.
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
    exit 0
fi

# ── Compose path (default) ─────────────────────────────────────────
if ! command -v podman-compose &>/dev/null; then
    echo "error: podman-compose not installed." >&2
    echo "  Fedora Silverblue:  rpm-ostree install podman-compose" >&2
    echo "  Fedora Workstation: sudo dnf install podman-compose" >&2
    echo "  Or re-run with --legacy for the direct podman path." >&2
    exit 1
fi

COMPOSE_BASE="$ROOT/src-tauri/assets/compose/compose.yaml"
COMPOSE_OVERLAY="$ROOT/src-tauri/assets/compose/compose.local.yaml"
for f in "$COMPOSE_BASE" "$COMPOSE_OVERLAY"; do
    if [[ ! -f "$f" ]]; then
        echo "error: compose file missing: $f" >&2
        echo "  Re-run with --legacy until task 6 of migrate-enclave-orchestration-to-compose is complete." >&2
        exit 1
    fi
done

NAME_SUFFIX="${NAME:-$PROJECT-local}"
PROJECT_NAME="tillandsias-$NAME_SUFFIX"

# Env vars consumed by compose.yaml and compose.local.yaml.
export TILLANDSIAS_VERSION="$VERSION"
export PROJECT_ID="$PROJECT"
export TILLANDSIAS_PROJECT_PATH="$SRC_ABS"
# HOME is referenced by the prod compose.yaml for the inference bind-mount.
# The local overlay never starts inference, but compose still evaluates the
# variable during the merge step; ensure it's set.
export HOME="${HOME:-/root}"

MOUNT_DEST="/home/forge/src/$PROJECT"
echo "[run-forge-standalone] mode      : COMPOSE (-f compose.yaml -f compose.local.yaml)"
echo "[run-forge-standalone] image     : $IMAGE"
echo "[run-forge-standalone] project   : $PROJECT_NAME"
echo "[run-forge-standalone] mount     : $SRC_ABS -> $MOUNT_DEST (rw)"

COMPOSE_ARGS=(
    -f "$COMPOSE_BASE"
    -f "$COMPOSE_OVERLAY"
    -p "$PROJECT_NAME"
)

if [[ "$DETACH" -eq 1 ]]; then
    # `up -d forge` brings up only the forge service (proxy/git/inference
    # are in the inactive `enclave` profile in compose.local.yaml).
    # --no-build keeps compose from second-guessing the Nix build pipeline.
    exec podman-compose "${COMPOSE_ARGS[@]}" up -d --no-build forge
fi

# Interactive: `run --rm forge bash` creates a one-off container with the
# overlay's bind mounts and removes it on exit. Matches the legacy
# `podman run -it --rm ... bash` semantics. --no-deps because nothing
# else should start.
exec podman-compose "${COMPOSE_ARGS[@]}" run --rm --no-deps forge bash
