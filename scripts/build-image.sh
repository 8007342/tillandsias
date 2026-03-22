#!/usr/bin/env bash
# Build container images using Nix inside the builder toolbox.
# Usage: scripts/build-image.sh [forge|web] [--force]
#
# This script:
#   1. Ensures the builder toolbox exists (via ensure-builder.sh)
#   2. Checks if sources have changed since last build (staleness detection)
#   3. Runs `nix build` inside the builder toolbox to produce a tarball
#   4. Loads the tarball into podman and tags the image
#
# Environment:
#   TILLANDSIAS_BUILD_VERBOSE=1   Show nix build output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILDER_TOOLBOX="tillandsias-builder"
CACHE_DIR="$ROOT/.nix-output"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[build-image]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[build-image]${NC} $*"; }
_error() { echo -e "${RED}[build-image]${NC} $*" >&2; }
_step()  { echo -e "${CYAN}[build-image]${NC} $*"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
IMAGE_NAME="forge"
FLAG_FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        forge|web)
            IMAGE_NAME="$1"
            ;;
        --force)
            FLAG_FORCE=true
            ;;
        --help|-h)
            echo "Usage: scripts/build-image.sh [forge|web] [--force]"
            echo ""
            echo "Build a container image using Nix inside the builder toolbox."
            echo ""
            echo "Arguments:"
            echo "  forge       Build the forge (dev environment) image (default)"
            echo "  web         Build the web server image"
            echo "  --force     Rebuild even if sources haven't changed"
            exit 0
            ;;
        *)
            _error "Unknown argument: $1 (try --help)"
            exit 1
            ;;
    esac
    shift
done

IMAGE_TAG="tillandsias-${IMAGE_NAME}:latest"
NIX_ATTR="${IMAGE_NAME}-image"
HASH_FILE="$CACHE_DIR/.last-build-${IMAGE_NAME}.sha256"

_step "Building image: ${BOLD}${IMAGE_TAG}${NC}"

# ---------------------------------------------------------------------------
# Step 1: Ensure builder toolbox exists
# ---------------------------------------------------------------------------
_step "Ensuring builder toolbox..."
"$SCRIPT_DIR/ensure-builder.sh"

# ---------------------------------------------------------------------------
# Step 2: Staleness detection
# ---------------------------------------------------------------------------
mkdir -p "$CACHE_DIR"

_compute_hash() {
    # Hash the flake definition, lock file, and image source files.
    # Any change to these means the image needs rebuilding.
    local files=()

    # Flake files (always relevant)
    [[ -f "$ROOT/flake.nix" ]]  && files+=("$ROOT/flake.nix")
    [[ -f "$ROOT/flake.lock" ]] && files+=("$ROOT/flake.lock")

    # Image source directories — hash all files in default/ and web/
    for dir in "$ROOT/images/default" "$ROOT/images/web"; do
        if [[ -d "$dir" ]]; then
            while IFS= read -r -d '' f; do
                files+=("$f")
            done < <(find "$dir" -type f -print0 2>/dev/null)
        fi
    done

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "no-sources"
        return
    fi

    sha256sum "${files[@]}" 2>/dev/null | sha256sum | cut -d' ' -f1
}

CURRENT_HASH="$(_compute_hash)"

if [[ "$FLAG_FORCE" == false ]] && [[ -f "$HASH_FILE" ]]; then
    LAST_HASH="$(cat "$HASH_FILE")"
    if [[ "$CURRENT_HASH" == "$LAST_HASH" ]]; then
        # Verify the image actually exists in podman
        if podman image exists "$IMAGE_TAG" 2>/dev/null; then
            _info "Image ${BOLD}${IMAGE_TAG}${NC} is up to date (sources unchanged)"
            exit 0
        else
            _warn "Hash matches but image not found in podman, rebuilding..."
        fi
    fi
fi

if [[ "$FLAG_FORCE" == true ]]; then
    _info "Force rebuild requested"
fi

# ---------------------------------------------------------------------------
# Step 3: Build image via Nix inside the builder toolbox
# ---------------------------------------------------------------------------
BUILD_START="$(date +%s)"
_step "Running nix build .#${NIX_ATTR} inside ${BUILDER_TOOLBOX}..."

NIX_CMD="cd $ROOT && nix build .#${NIX_ATTR} --print-out-paths --no-link 2>/dev/null"
TARBALL_PATH="$(toolbox run -c "$BUILDER_TOOLBOX" bash -lc "$NIX_CMD" | tail -1 | tr -d '[:space:]')"

if [[ -z "$TARBALL_PATH" ]]; then
    _error "Nix build failed — no output path returned"
    exit 1
fi

_info "Tarball: $TARBALL_PATH (inside builder toolbox)"

# ---------------------------------------------------------------------------
# Step 4: Stream tarball from builder toolbox → podman load on host
# ---------------------------------------------------------------------------
# The tarball lives inside the builder toolbox's /nix/store/ which is NOT
# accessible from the host. We stream it via cat through the toolbox.
_step "Loading image into podman..."
LOAD_OUTPUT="$(toolbox run -c "$BUILDER_TOOLBOX" cat "$TARBALL_PATH" | podman load 2>&1)"
echo "$LOAD_OUTPUT" | while IFS= read -r line; do
    _info "  $line"
done

# Extract the loaded image name from podman load output
# "Loaded image: localhost/tillandsias-forge:latest" or "Loaded image(s): ..."
LOADED_IMAGE="$(echo "$LOAD_OUTPUT" | grep 'Loaded image' | sed 's/.*: //' | tail -1 | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
# Step 5: Tag the image
# ---------------------------------------------------------------------------
if [[ -n "$LOADED_IMAGE" ]] && [[ "$LOADED_IMAGE" != "$IMAGE_TAG" ]]; then
    _step "Tagging as ${IMAGE_TAG}..."
    podman tag "$LOADED_IMAGE" "$IMAGE_TAG"
elif [[ -z "$LOADED_IMAGE" ]]; then
    _warn "Could not detect loaded image name from podman output"
    _warn "Attempting to tag by inspecting recent images..."
    # Fallback: the nix-built image often uses a specific name
    # Try tagging whatever was just loaded
fi

# Verify the image exists
if ! podman image exists "$IMAGE_TAG" 2>/dev/null; then
    _error "Image ${IMAGE_TAG} not found after load. Something went wrong."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 6: Save hash for staleness detection
# ---------------------------------------------------------------------------
echo "$CURRENT_HASH" > "$HASH_FILE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
BUILD_END="$(date +%s)"
BUILD_DURATION=$(( BUILD_END - BUILD_START ))

# Get image size
IMAGE_SIZE="$(podman image inspect "$IMAGE_TAG" --format '{{.Size}}' 2>/dev/null || echo "")"
if [[ -n "$IMAGE_SIZE" ]]; then
    SIZE_MB=$(( IMAGE_SIZE / 1024 / 1024 ))
    SIZE_DISPLAY="${SIZE_MB} MB"
else
    SIZE_DISPLAY="unknown"
fi

echo ""
_info "----------------------------------------------"
_info "Image:    ${BOLD}${IMAGE_TAG}${NC}"
_info "Size:     ${SIZE_DISPLAY}"
_info "Time:     ${BUILD_DURATION}s"
_info "Tarball:  ${TARBALL_PATH}"
_info "----------------------------------------------"
