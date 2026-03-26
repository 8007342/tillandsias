#!/usr/bin/env bash
# Build container images using Nix inside an ephemeral podman container.
# Usage: scripts/build-image.sh [forge|web] [--force]
#
# This script:
#   1. Checks if sources have changed since last build (staleness detection)
#   2. Runs `nix build` inside an ephemeral `nixos/nix:latest` container
#   3. Loads the resulting tarball into podman and tags the image
#
# No toolbox dependency — works on any system with podman.
#
# Environment:
#   TILLANDSIAS_BUILD_VERBOSE=1   Show nix build output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Pinned for reproducibility. Update: podman pull docker.io/nixos/nix:<new-version>
NIX_IMAGE="docker.io/nixos/nix:2.34.4"
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
            echo "Build a container image using Nix inside an ephemeral podman container."
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

# Verify flake.nix exists at ROOT (required for nix build)
if [[ ! -f "$ROOT/flake.nix" ]]; then
    _error "flake.nix not found at $ROOT/"
    _error "When installed, flake.nix should be at ~/.local/share/tillandsias/flake.nix"
    _error "Run './build.sh --install' from the project directory to fix this."
    exit 1
fi

_step "Building image: ${BOLD}${IMAGE_TAG}${NC}"

# ---------------------------------------------------------------------------
# Step 1: Staleness detection
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
# Step 2: Build image via Nix inside an ephemeral podman container
# ---------------------------------------------------------------------------
BUILD_START="$(date +%s)"

# Output directory for the tarball (host-side)
OUTPUT_DIR="$CACHE_DIR/build-output"
mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/result.tar.gz"

_step "Running nix build .#${NIX_ATTR} inside ephemeral ${NIX_IMAGE} container..."

# Mount the source tree read-only at /src and an output volume at /output.
# The nix build produces a tarball in /nix/store/; we copy it to /output
# so it's accessible on the host after the container exits.
#
# --extra-experimental-features ensures flakes work regardless of the
# image's default nix.conf.
NIX_BUILD_CMD="nix --extra-experimental-features 'nix-command flakes' build /src#${NIX_ATTR} --print-out-paths --no-link 2>&1 | tee /dev/stderr | tail -1 | xargs -I{} cp {} /output/result.tar.gz"

# --security-opt label=disable bypasses SELinux label checks entirely.
# Required on Silverblue where source files may be on tmpfs ($XDG_RUNTIME_DIR)
# or have unexpected SELinux contexts. This is the same approach used for
# forge containers in handlers.rs.
podman run --rm \
    --security-opt label=disable \
    -v "$ROOT:/src:ro" \
    -v "$OUTPUT_DIR:/output:rw" \
    "$NIX_IMAGE" \
    bash -c "$NIX_BUILD_CMD"

TARBALL_PATH="$OUTPUT_DIR/result.tar.gz"

if [[ ! -f "$TARBALL_PATH" ]]; then
    _error "Nix build failed — no tarball produced at $TARBALL_PATH"
    exit 1
fi

_info "Tarball: $TARBALL_PATH"

# ---------------------------------------------------------------------------
# Step 3: Load tarball into podman
# ---------------------------------------------------------------------------
_step "Loading image into podman..."
LOAD_OUTPUT="$(podman load < "$TARBALL_PATH" 2>&1)"
echo "$LOAD_OUTPUT" | while IFS= read -r line; do
    _info "  $line"
done

# Extract the loaded image name from podman load output
# "Loaded image: localhost/tillandsias-forge:latest" or "Loaded image(s): ..."
LOADED_IMAGE="$(echo "$LOAD_OUTPUT" | grep 'Loaded image' | sed 's/.*: //' | tail -1 | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
# Step 4: Tag the image
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
# Step 5: Save hash for staleness detection
# ---------------------------------------------------------------------------
echo "$CURRENT_HASH" > "$HASH_FILE"

# Clean up the build output tarball
rm -f "$TARBALL_PATH"

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
_info "----------------------------------------------"
