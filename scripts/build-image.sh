#!/usr/bin/env bash
# Build container images using Nix inside an ephemeral podman container.
# Usage: scripts/build-image.sh [forge|web|proxy|git|inference] [--force]
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

# @trace spec:nix-builder, spec:default-image, spec:dev-build

# ---------------------------------------------------------------------------
# macOS PATH fix: Finder-launched apps don't inherit shell PATH.
# Ensure common tool directories are reachable (Homebrew, MacPorts, etc.)
# Linux is unaffected — this block is a no-op there.
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" == "Darwin" ]]; then
    for _dir in /opt/homebrew/bin /opt/local/bin /usr/local/bin; do
        [[ -d "$_dir" ]] && [[ ":$PATH:" != *":$_dir:"* ]] && export PATH="$_dir:$PATH"
    done
    unset _dir
fi

# Resolve the podman binary: prefer PODMAN_PATH from Rust caller, then
# check known absolute paths, then fall back to bare "podman" (PATH lookup).
if [[ -n "${PODMAN_PATH:-}" ]] && [[ -x "$PODMAN_PATH" ]]; then
    PODMAN="$PODMAN_PATH"
elif [[ -x /opt/homebrew/bin/podman ]]; then
    PODMAN=/opt/homebrew/bin/podman
elif [[ -x /opt/local/bin/podman ]]; then
    PODMAN=/opt/local/bin/podman
elif [[ -x /usr/local/bin/podman ]]; then
    PODMAN=/usr/local/bin/podman
elif [[ -x /usr/bin/podman ]]; then
    PODMAN=/usr/bin/podman
else
    PODMAN=podman
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Pinned for reproducibility. Update: podman pull docker.io/nixos/nix:<new-version>
NIX_IMAGE="docker.io/nixos/nix:2.34.4"
# Hash file must survive temp dir cleanup. When the app invokes this script,
# $ROOT is a temp dir that gets deleted after the build completes. Store the
# staleness hash in the user's cache dir so it persists across launches.
if [[ -d "$HOME/Library/Caches/tillandsias" ]]; then
    CACHE_DIR="$HOME/Library/Caches/tillandsias/build-hashes"
elif [[ -d "$HOME/.cache/tillandsias" ]]; then
    CACHE_DIR="$HOME/.cache/tillandsias/build-hashes"
else
    CACHE_DIR="$ROOT/.nix-output"
fi

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
FLAG_TAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        forge|web|proxy|git|inference|chromium-core|chromium-framework)
            IMAGE_NAME="$1"
            ;;
        --force)
            FLAG_FORCE=true
            ;;
        --tag)
            shift
            FLAG_TAG="$1"
            ;;
        --help|-h)
            echo "Usage: scripts/build-image.sh [forge|web|proxy|git|inference] [--force] [--tag <tag>]"
            echo ""
            echo "Build a container image using podman (Containerfile-based, reproducible)."
            echo ""
            echo "Arguments:"
            echo "  forge              Build the forge (dev environment) image (default)"
            echo "  web                Build the web server image"
            echo "  proxy              Build the enclave proxy image"
            echo "  git                Build the git service image"
            echo "  inference          Build the local LLM inference image"
            echo "  chromium-core      Build the secure browser container (minimal)"
            echo "  chromium-framework Build the debug browser container (with Node.js+Playwright)"
            echo "  --force            Rebuild even if sources haven't changed"
            echo "  --tag <tag>        Override the image tag (default: tillandsias-<name>:latest)"
            echo ""
            echo "Note: This script uses podman build with embedded Containerfiles."
            echo "No Nix required. Package cache is mounted for bandwidth optimization."
            exit 0
            ;;
        *)
            _error "Unknown argument: $1 (try --help)"
            exit 1
            ;;
    esac
    shift
done

if [[ -n "$FLAG_TAG" ]]; then
    IMAGE_TAG="$FLAG_TAG"
else
    IMAGE_TAG="tillandsias-${IMAGE_NAME}:latest"
fi
NIX_ATTR="${IMAGE_NAME}-image"
# Version the hash file with the image tag so each version has independent
# staleness state. Sanitize tag for filename (replace : and / with -).
HASH_SUFFIX="$(echo "$IMAGE_TAG" | tr ':/' '--')"
HASH_FILE="$CACHE_DIR/.last-build-${HASH_SUFFIX}.sha256"

# Verify Containerfile exists for the image type
case "$IMAGE_NAME" in
    web)       CONTAINERFILE="$ROOT/images/web/Containerfile" ;;
    proxy)     CONTAINERFILE="$ROOT/images/proxy/Containerfile" ;;
    git)       CONTAINERFILE="$ROOT/images/git/Containerfile" ;;
    inference) CONTAINERFILE="$ROOT/images/inference/Containerfile" ;;
    chromium-core) CONTAINERFILE="$ROOT/images/chromium/Containerfile.core" ;;
    chromium-framework) CONTAINERFILE="$ROOT/images/chromium/Containerfile.framework" ;;
    *)         CONTAINERFILE="$ROOT/images/default/Containerfile" ;;
esac

if [[ ! -f "$CONTAINERFILE" ]]; then
    _error "Containerfile not found at $CONTAINERFILE"
    exit 1
fi

_step "Building image: ${BOLD}${IMAGE_TAG}${NC}"

# ---------------------------------------------------------------------------
# Step 1: Staleness detection
# ---------------------------------------------------------------------------
mkdir -p "$CACHE_DIR"

# Clean up old unversioned hash files (legacy format: .last-build-forge.sha256)
# These carry over across version bumps, creating false "up to date" results.
# @trace spec:forge-staleness
for _old in "$CACHE_DIR/.last-build-forge.sha256" \
            "$CACHE_DIR/.last-build-proxy.sha256" \
            "$CACHE_DIR/.last-build-git.sha256" \
            "$CACHE_DIR/.last-build-inference.sha256" \
            "$CACHE_DIR/.last-build-web.sha256"; do
    if [[ -f "$_old" ]]; then
        _info "Removing legacy hash file: $(basename "$_old")"
        rm -f "$_old"
    fi
done
unset _old

_compute_hash() {
    # Hash Containerfile and related source files in the image directory.
    # @trace spec:user-runtime-lifecycle
    local image_dir="$1"
    local files=()

    if [[ ! -d "$image_dir" ]]; then
        echo "no-sources"
        return
    fi

    # Hash all files in the image directory (Containerfile + support scripts)
    while IFS= read -r -d '' f; do
        [[ -n "$f" ]] && files+=("$f")
    done < <(find "$image_dir" -type f -print0 2>/dev/null)

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "no-sources"
        return
    fi

    sha256sum "${files[@]}" 2>/dev/null | sha256sum | cut -d' ' -f1
}

IMAGE_DIR="${CONTAINERFILE%/*}"
CURRENT_HASH="$(_compute_hash "$IMAGE_DIR")"

if [[ "$FLAG_FORCE" == false ]] && [[ -f "$HASH_FILE" ]]; then
    LAST_HASH="$(cat "$HASH_FILE")"
    if [[ "$CURRENT_HASH" == "$LAST_HASH" ]]; then
        # Verify the image actually exists in podman
        if "$PODMAN" image exists "$IMAGE_TAG" 2>/dev/null; then
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
# Step 2: Build image (pure podman + cache mounting)
# ---------------------------------------------------------------------------
# @trace spec:user-runtime-lifecycle, spec:podman-orchestration
BUILD_START="$(date +%s)"

_step "Building ${BOLD}${IMAGE_TAG}${NC} via podman build (Containerfile)..."

# Detect distro from Containerfile for cache mounting
# @trace spec:user-runtime-lifecycle
_detect_distro() {
    local containerfile="$1"
    if grep -q "^FROM.*fedora" "$containerfile"; then
        echo "fedora"
    elif grep -q "^FROM.*debian\|^FROM.*ubuntu" "$containerfile"; then
        echo "debian"
    elif grep -q "^FROM.*alpine" "$containerfile"; then
        echo "alpine"
    else
        echo "unknown"
    fi
}

DISTRO="$(_detect_distro "$CONTAINERFILE")"
_info "Detected base distro: ${BOLD}${DISTRO}${NC}"

# Set up cache mount for distro-specific package manager
# @trace spec:user-runtime-lifecycle
CACHE_MOUNT_ARGS=()
PACKAGE_CACHE="$HOME/.cache/tillandsias/packages"
if [[ -n "$HOME" ]]; then
    mkdir -p "$PACKAGE_CACHE"
    case "$DISTRO" in
        fedora)
            CACHE_MOUNT_ARGS=("-v" "$PACKAGE_CACHE:/var/cache/dnf/packages")
            _info "Package cache: $PACKAGE_CACHE → /var/cache/dnf/packages"
            ;;
        debian)
            CACHE_MOUNT_ARGS=("-v" "$PACKAGE_CACHE:/var/cache/apt/archives")
            _info "Package cache: $PACKAGE_CACHE → /var/cache/apt/archives"
            ;;
        alpine)
            CACHE_MOUNT_ARGS=("-v" "$PACKAGE_CACHE:/var/cache/apk")
            _info "Package cache: $PACKAGE_CACHE → /var/cache/apk"
            ;;
        *)
            _warn "Unknown distro, skipping cache mount"
            ;;
    esac
fi

# Remove any existing tags for this image name to prevent double-tagging
EXISTING_TAGS=$("$PODMAN" images --format "{{.Repository}}:{{.Tag}}" | grep "tillandsias-${IMAGE_NAME}:" || true)
for old_tag in $EXISTING_TAGS; do
    old_tag_normalized=$(echo "$old_tag" | sed 's|^localhost/||')
    if [[ "$old_tag_normalized" != "$IMAGE_TAG" ]]; then
        _info "  Removing old tag: $old_tag"
        "$PODMAN" rmi -f "$old_tag" 2>/dev/null || true
    fi
done

# Build args: pass CHROMIUM_CORE_TAG for framework images
BUILD_ARGS=()
if [[ "$IMAGE_NAME" == "chromium-framework" ]]; then
    CHROMIUM_CORE_TAG=$(echo "$IMAGE_TAG" | sed 's/.*://')
    BUILD_ARGS+=(--build-arg "CHROMIUM_CORE_TAG=${CHROMIUM_CORE_TAG}")
fi

# Image builds do NOT go through the proxy — SSL bump requires CA trust
# that build containers don't have. Proxy is for runtime containers only.
# @trace spec:user-runtime-lifecycle

"$PODMAN" build \
    --format docker \
    --tag "$IMAGE_TAG" \
    "${BUILD_ARGS[@]}" \
    "${CACHE_MOUNT_ARGS[@]}" \
    -f "$CONTAINERFILE" \
    "$IMAGE_DIR/"

# Remove :latest tag if it exists and differs from IMAGE_TAG
LATEST_TAG="tillandsias-${IMAGE_NAME}:latest"
if [[ "$IMAGE_TAG" != "$LATEST_TAG" ]]; then
    _info "  Removing ${LATEST_TAG} tag if present..."
    "$PODMAN" rmi "$LATEST_TAG" 2>/dev/null || true
fi

    # Verify the image exists — retry briefly because podman storage may need
    # a moment to flush after a build completes (prevents false negatives).
    # @trace spec:default-image
    _image_found=false
    for _attempt in 1 2 3; do
        if "$PODMAN" image exists "$IMAGE_TAG" 2>/dev/null; then
            _image_found=true
            break
        fi
        _warn "Image ${IMAGE_TAG} not found on attempt ${_attempt}/3, retrying..."
        sleep 1
    done

    if [[ "$_image_found" == false ]]; then
        _error "Image ${IMAGE_TAG} not found after build + 3 retries. Something went wrong."
        exit 1
    fi

    # Remove ANY tags for this image name that don't match IMAGE_TAG
    # (podman may have left old tags on the same image ID)
    # Note: podman may add localhost/ prefix, so we normalize for comparison
    ALL_TAGS="$("$PODMAN" images --format "{{.Repository}}:{{.Tag}}" | grep "tillandsias-${IMAGE_NAME}:" || true)"
    for old_tag in $ALL_TAGS; do
        old_tag_normalized=$(echo "$old_tag" | sed 's|^localhost/||')
        if [[ "$old_tag_normalized" != "$IMAGE_TAG" ]]; then
            _info "  Removing stale tag: $old_tag"
            "$PODMAN" rmi -f "$old_tag" 2>/dev/null || true
        fi
    done

# ---------------------------------------------------------------------------
# Step 5: Save hash for staleness detection
# ---------------------------------------------------------------------------
echo "$CURRENT_HASH" > "$HASH_FILE"

# Clean up the build output tarball (Nix backend only)
if [[ -n "${TARBALL_PATH:-}" ]]; then
    rm -f "$TARBALL_PATH"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
BUILD_END="$(date +%s)"
BUILD_DURATION=$(( BUILD_END - BUILD_START ))

# Get image size
IMAGE_SIZE="$("$PODMAN" image inspect "$IMAGE_TAG" --format '{{.Size}}' 2>/dev/null || echo "")"
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

# Explicit success exit (podman build may return non-zero even on success)
exit 0
