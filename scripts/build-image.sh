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

# @trace spec:nix-builder, spec:default-image

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
FLAG_BACKEND="fedora"  # Default: Fedora minimal. Use --backend nix for Nix image.

while [[ $# -gt 0 ]]; do
    case "$1" in
        forge|web|proxy|git|inference)
            IMAGE_NAME="$1"
            ;;
        --force)
            FLAG_FORCE=true
            ;;
        --tag)
            shift
            FLAG_TAG="$1"
            ;;
        --backend)
            shift
            FLAG_BACKEND="$1"
            ;;
        --help|-h)
            echo "Usage: scripts/build-image.sh [forge|web|proxy|git|inference] [--force] [--tag <tag>] [--backend fedora|nix]"
            echo ""
            echo "Build a container image."
            echo ""
            echo "Arguments:"
            echo "  forge              Build the forge (dev environment) image (default)"
            echo "  web                Build the web server image"
            echo "  proxy              Build the enclave proxy image"
            echo "  git                Build the git service image"
            echo "  inference          Build the local LLM inference image"
            echo "  --force            Rebuild even if sources haven't changed"
            echo "  --tag <tag>        Override the image tag (default: tillandsias-<name>:latest)"
            echo "  --backend <type>   Build backend: fedora (default) or nix"
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

# Verify required files exist based on backend
if [[ "$FLAG_BACKEND" == "nix" ]] && [[ ! -f "$ROOT/flake.nix" ]]; then
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

_is_git_repo() {
    git -C "$ROOT" rev-parse --is-inside-work-tree &>/dev/null
}

# @trace spec:nix-builder/git-tracked-files
_check_untracked_image_sources() {
    # Fail early if untracked files exist in image source dirs — they would
    # be silently excluded from the Nix flake build, producing wrong images.
    if ! _is_git_repo; then
        return 0
    fi
    local untracked
    untracked="$(git -C "$ROOT" ls-files --others --exclude-standard -- images/default images/web images/proxy images/git images/inference 2>/dev/null)"
    if [[ -n "$untracked" ]]; then
        _error "Untracked files in image sources (Nix will silently exclude them):"
        while IFS= read -r f; do
            _error "  $f"
        done <<< "$untracked"
        _error "Stage them with: git add <files>"
        exit 1
    fi
}

_compute_hash() {
    # Hash the flake definition, lock file, and image source files.
    # Uses git ls-files to match what Nix flake builds actually see.
    # @trace spec:nix-builder/git-tracked-files
    local files=()

    # Flake files (always relevant)
    [[ -f "$ROOT/flake.nix" ]]  && files+=("$ROOT/flake.nix")
    [[ -f "$ROOT/flake.lock" ]] && files+=("$ROOT/flake.lock")

    # Image source directories — use git ls-files to match Nix's view
    if _is_git_repo; then
        for dir in images/default images/web images/proxy images/git images/inference; do
            while IFS= read -r f; do
                [[ -n "$f" ]] && files+=("$ROOT/$f")
            done < <(git -C "$ROOT" ls-files -- "$dir" 2>/dev/null)
        done
    else
        _warn "Not a git repo — falling back to find (untracked file detection unavailable)"
        for dir in "$ROOT/images/default" "$ROOT/images/web" "$ROOT/images/proxy" "$ROOT/images/git" "$ROOT/images/inference"; do
            if [[ -d "$dir" ]]; then
                while IFS= read -r -d '' f; do
                    files+=("$f")
                done < <(find "$dir" -type f -print0 2>/dev/null)
            fi
        done
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "no-sources"
        return
    fi

    sha256sum "${files[@]}" 2>/dev/null | sha256sum | cut -d' ' -f1
}

_check_untracked_image_sources
CURRENT_HASH="$(_compute_hash)"

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
# Step 2: Build image
# ---------------------------------------------------------------------------
BUILD_START="$(date +%s)"

if [[ "$FLAG_BACKEND" == "fedora" ]]; then
    # ── Fedora backend: podman build with Containerfile ────────
    # Route to the correct image directory based on IMAGE_NAME.
    # @trace spec:proxy-container
    case "$IMAGE_NAME" in
        web)       IMAGE_DIR="$ROOT/images/web" ;;
        proxy)     IMAGE_DIR="$ROOT/images/proxy" ;;
        git)       IMAGE_DIR="$ROOT/images/git" ;;
        inference) IMAGE_DIR="$ROOT/images/inference" ;;
        *)         IMAGE_DIR="$ROOT/images/default" ;;
    esac
    _step "Building ${BOLD}${IMAGE_TAG}${NC} via podman build (Fedora minimal)..."
    CONTAINERFILE="$IMAGE_DIR/Containerfile"
    if [[ ! -f "$CONTAINERFILE" ]]; then
        _error "Containerfile not found at $CONTAINERFILE"
        exit 1
    fi

    # Pass proxy env vars as build args if available.
    # Image builds do NOT go through the proxy — SSL bump requires CA trust
    # that build containers don't have. Proxy is for runtime containers only.

    "$PODMAN" build \
        --tag "$IMAGE_TAG" \
        -f "$CONTAINERFILE" \
        "$IMAGE_DIR/"

else
    # ── Nix backend: nix build inside ephemeral container ─────
    # @trace spec:nix-builder/ephemeral-nix-build, knowledge:packaging/nix-flakes
    OUTPUT_DIR="$CACHE_DIR/build-output"
    mkdir -p "$OUTPUT_DIR"
    rm -f "$OUTPUT_DIR/result.tar.gz"

    _step "Running nix build .#${NIX_ATTR} inside ephemeral ${NIX_IMAGE} container..."

    NIX_BUILD_CMD="nix --extra-experimental-features 'nix-command flakes' build /src#${NIX_ATTR} --print-out-paths --no-link 2>&1 | tee /dev/stderr | tail -1 | xargs -I{} cp {} /output/result.tar.gz"

    # --security-opt label=disable bypasses SELinux label checks.
    "$PODMAN" run --rm \
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

    # Load tarball into podman
    _step "Loading image into podman..."
    LOAD_OUTPUT="$("$PODMAN" load < "$TARBALL_PATH" 2>&1)"
    echo "$LOAD_OUTPUT" | while IFS= read -r line; do
        _info "  $line"
    done

    LOADED_IMAGE="$(echo "$LOAD_OUTPUT" | grep 'Loaded image' | sed 's/.*: //' | tail -1 | tr -d '[:space:]')"

    if [[ -n "$LOADED_IMAGE" ]] && [[ "$LOADED_IMAGE" != "$IMAGE_TAG" ]]; then
        _step "Tagging as ${IMAGE_TAG}..."
        "$PODMAN" tag "$LOADED_IMAGE" "$IMAGE_TAG"
    fi
fi

# Verify the image exists
if ! "$PODMAN" image exists "$IMAGE_TAG" 2>/dev/null; then
    _error "Image ${IMAGE_TAG} not found after load. Something went wrong."
    exit 1
fi

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
