#!/usr/bin/env bash
# Build container images directly with podman and source-hash caching.
# Usage: scripts/build-image.sh [forge|web|proxy|git|inference] [--force]
# @trace spec:forge-standalone-runner
#
# This script:
#   1. Checks if sources have changed since last build (staleness detection)
#   2. Builds with podman using pinned Containerfile bases
#   3. Tags the resulting image with a content hash and human aliases
#
# No toolbox dependency — works on any system with podman.
#
# Environment:
#   TILLANDSIAS_BUILD_VERBOSE=1   Show raw podman build output

set -euo pipefail

# @trace spec:default-image, spec:dev-build, spec:podman-orchestration, spec:nix-builder

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
require_podman

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Hash file must survive temp dir cleanup. Prefer a writable user cache, but
# fall back to the repo-local cache if the host cache is read-only.
CACHE_DIR=""
for _candidate_cache in \
    "$HOME/Library/Caches/tillandsias/build-hashes" \
    "$HOME/.cache/tillandsias/build-hashes" \
    "$ROOT/.nix-output"; do
    if mkdir -p "$_candidate_cache" 2>/dev/null && [[ -w "$_candidate_cache" ]]; then
        CACHE_DIR="$_candidate_cache"
        break
    fi
done
if [[ -z "$CACHE_DIR" ]]; then
    _error "Unable to create a writable build hash cache directory"
    exit 1
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

_verbose_enabled() {
    [[ "${TILLANDSIAS_BUILD_VERBOSE:-0}" == "1" ]]
}

_verbose_info() {
    if _verbose_enabled; then
        _info "$@"
    fi
}

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
            echo "  --tag <tag>        Override the canonical image tag (default: content hash)"
            echo "                     Human aliases still track v$(cat "$ROOT/VERSION") and :latest"
            echo ""
            echo "Note: This script uses podman build with embedded Containerfiles."
            echo "No Nix required. Builds use no persistent package cache."
            exit 0
            ;;
        *)
            _error "Unknown argument: $1 (try --help)"
            exit 1
            ;;
    esac
    shift
done

IMAGE_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
if [[ -z "$IMAGE_VERSION" ]]; then
    _error "VERSION file is empty"
    exit 1
fi
IMAGE_LABEL_PREFIX="tillandsias-${IMAGE_NAME}"
IMAGE_VERSION_TAG="${IMAGE_LABEL_PREFIX}:v${IMAGE_VERSION}"
IMAGE_LATEST_TAG="${IMAGE_LABEL_PREFIX}:latest"
USE_HUMAN_ALIASES=true
if [[ -n "$FLAG_TAG" ]]; then
    IMAGE_CANONICAL_TAG="$FLAG_TAG"
    USE_HUMAN_ALIASES=false
else
    IMAGE_CANONICAL_TAG=""
fi
# Staleness state is keyed by image name, not version, so version bumps do not
# force rebuilds when the source hash is unchanged.
HASH_FILE="$CACHE_DIR/.last-build-${IMAGE_NAME}.sha256"

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

# ---------------------------------------------------------------------------
# Step 1: Aggressive stale-state cleanup + staleness detection
# ---------------------------------------------------------------------------
mkdir -p "$CACHE_DIR"

_remove_stale_hashes() {
    local hash
    shopt -s nullglob
    for hash in "$CACHE_DIR/.last-build-${IMAGE_NAME}.sha256" \
                "$CACHE_DIR/.last-build-tillandsias-${IMAGE_NAME}-"*.sha256; do
        if [[ "$hash" != "$HASH_FILE" ]]; then
            _verbose_info "Removing stale build hash: $(basename "$hash")"
            rm -f "$hash" 2>/dev/null || true
        fi
    done
    shopt -u nullglob
}

_is_kept_image_tag() {
    local candidate="$1"
    if [[ "$USE_HUMAN_ALIASES" == true ]]; then
        case "$candidate" in
            "$IMAGE_TAG"|"$IMAGE_VERSION_TAG"|"$IMAGE_LATEST_TAG")
                return 0
                ;;
        esac
    else
        case "$candidate" in
            "$IMAGE_TAG")
                return 0
                ;;
        esac
    fi
    return 1
}

_remove_stale_image_tags() {
    local tags old_tag old_tag_normalized
    tags="$("$PODMAN" images --format "{{.Repository}}:{{.Tag}}" | grep "tillandsias-${IMAGE_NAME}:" || true)"
    for old_tag in $tags; do
        old_tag_normalized="$(echo "$old_tag" | sed 's|^localhost/||')"
        if ! _is_kept_image_tag "$old_tag_normalized"; then
            _verbose_info "Removing stale image tag: $old_tag"
            if _verbose_enabled; then
                "$PODMAN" rmi -f "$old_tag" || true
            else
                "$PODMAN" rmi -f "$old_tag" >/dev/null 2>&1 || true
            fi
        fi
    done
}

# Clean up old hash files before any freshness shortcut. Stale hashes carry
# over across version bumps and create false "up to date" results.
# @trace spec:forge-staleness, spec:init-incremental-builds
_remove_stale_hashes

_compute_hash() {
    # Hash Containerfile and related source files in the image directory.
    # @trace spec:user-runtime-lifecycle, spec:init-incremental-builds, spec:nix-builder
    local image_dir="$1"
    local image_rel
    local -a file_list=() tracked_rel=() untracked_rel=()

    if [[ ! -d "$image_dir" ]]; then
        echo "no-sources"
        return
    fi

    image_rel="${image_dir#"$ROOT"/}"

    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        mapfile -d '' -t untracked_rel < <(git -C "$ROOT" ls-files --others --exclude-standard -z -- "$image_rel" 2>/dev/null || true)
        if [[ ${#untracked_rel[@]} -gt 0 ]]; then
            _error "Untracked files detected under ${image_rel}:"
            printf '  %s\n' "${untracked_rel[@]}" >&2
            _error "Run git add before rebuilding image sources."
            exit 1
        fi

        mapfile -d '' -t tracked_rel < <(git -C "$ROOT" ls-files -z -- "$image_rel" 2>/dev/null || true)
        for rel in "${tracked_rel[@]}"; do
            [[ -n "$rel" ]] && file_list+=("$ROOT/$rel")
        done
    else
        _warn "Not in a git repository; falling back to find-based source enumeration for ${image_rel}"
        while IFS= read -r -d '' f; do
            [[ -n "$f" ]] && file_list+=("$f")
        done < <(find "$image_dir" -type f -print0 2>/dev/null | sort -z)
    fi

    if [[ ${#file_list[@]} -eq 0 ]]; then
        echo "no-sources"
        return
    fi

    sha256sum "${file_list[@]}" 2>/dev/null | sha256sum | cut -d' ' -f1
}

IMAGE_DIR="${CONTAINERFILE%/*}"
CURRENT_HASH="$(_compute_hash "$IMAGE_DIR")"

if [[ -z "$FLAG_TAG" ]]; then
    IMAGE_CANONICAL_TAG="${IMAGE_LABEL_PREFIX}:${CURRENT_HASH}"
fi
IMAGE_TAG="$IMAGE_CANONICAL_TAG"

_remove_stale_image_tags

_step "Building image: ${BOLD}${IMAGE_TAG}${NC}"

_source_tag=""
for _candidate in "$IMAGE_TAG" "$IMAGE_VERSION_TAG" "$IMAGE_LATEST_TAG"; do
    if "$PODMAN" image exists "$_candidate" 2>/dev/null; then
        _source_tag="$_candidate"
        break
    fi
done

_apply_alias_tags() {
    local source_tag="$1"
    [[ "$USE_HUMAN_ALIASES" == true ]] || return 0
    if [[ "$source_tag" != "$IMAGE_VERSION_TAG" ]]; then
        if "$PODMAN" image exists "$IMAGE_VERSION_TAG" 2>/dev/null; then
            _verbose_info "Removing stale version tag: $IMAGE_VERSION_TAG"
            "$PODMAN" rmi "$IMAGE_VERSION_TAG" >/dev/null 2>&1 || true
        fi
        _verbose_info "Tagging ${source_tag} -> ${IMAGE_VERSION_TAG}"
        "$PODMAN" tag "$source_tag" "$IMAGE_VERSION_TAG" >/dev/null 2>&1 || true
    fi
    if [[ "$source_tag" != "$IMAGE_LATEST_TAG" ]]; then
        if "$PODMAN" image exists "$IMAGE_LATEST_TAG" 2>/dev/null; then
            _verbose_info "Removing stale latest tag: $IMAGE_LATEST_TAG"
            "$PODMAN" rmi "$IMAGE_LATEST_TAG" >/dev/null 2>&1 || true
        fi
        _verbose_info "Tagging ${source_tag} -> ${IMAGE_LATEST_TAG}"
        "$PODMAN" tag "$source_tag" "$IMAGE_LATEST_TAG" >/dev/null 2>&1 || true
    fi
}

if [[ "$FLAG_FORCE" == false ]] && [[ -f "$HASH_FILE" ]]; then
    LAST_HASH="$(cat "$HASH_FILE")"
    if [[ "$CURRENT_HASH" == "$LAST_HASH" ]]; then
        # Verify the image actually exists in podman.
        # @trace spec:init-incremental-builds
        if [[ -n "$_source_tag" ]]; then
            if [[ "$_source_tag" != "$IMAGE_TAG" ]]; then
                _verbose_info "Tagging ${_source_tag} -> ${IMAGE_TAG}"
                "$PODMAN" tag "$_source_tag" "$IMAGE_TAG" >/dev/null 2>&1 || true
            fi
            _apply_alias_tags "$_source_tag"
            _remove_stale_image_tags
            _info "Image ${BOLD}${IMAGE_TAG}${NC} is up to date (sources unchanged)"
            exit 0
        fi
        _warn "Hash matches but image not found in podman, rebuilding..."
    fi
fi

if [[ "$FLAG_FORCE" == true ]]; then
    _info "Force rebuild requested"
fi

# ---------------------------------------------------------------------------
# Step 2: Build image (pure podman + cache mounting)
# ---------------------------------------------------------------------------
# @trace spec:user-runtime-lifecycle, spec:podman-orchestration, spec:init-incremental-builds
BUILD_START="$(date +%s)"

_step "Building ${BOLD}${IMAGE_TAG}${NC} via podman build (Containerfile)..."

# Detect distro from Containerfile for cache mounting
# @trace spec:user-runtime-lifecycle, spec:init-incremental-builds
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

# Package-manager caches are intentionally not persisted by build scripts.
# @trace spec:user-runtime-lifecycle, spec:init-incremental-builds
CACHE_MOUNT_ARGS=()
PACKAGE_CACHE="$HOME/.cache/tillandsias/packages"
if [[ -n "$HOME" ]]; then
    rm -rf "$PACKAGE_CACHE" 2>/dev/null || true
fi

# Build args: pass a resolved chromium-core image reference for framework images
BUILD_ARGS=()
if [[ "$IMAGE_NAME" == "chromium-framework" ]]; then
    resolve_chromium_core_image() {
        local candidate
        for candidate in \
            "tillandsias-chromium-core:${CURRENT_HASH}" \
            "tillandsias-chromium-core:v${IMAGE_VERSION}" \
            "tillandsias-chromium-core:latest" \
            "localhost/tillandsias-chromium-core:${CURRENT_HASH}" \
            "localhost/tillandsias-chromium-core:v${IMAGE_VERSION}" \
            "localhost/tillandsias-chromium-core:latest"; do
            if "$PODMAN" image exists "$candidate" 2>/dev/null; then
                echo "$candidate"
                return 0
            fi
        done
        return 1
    }

    CHROMIUM_CORE_IMAGE="$(resolve_chromium_core_image || true)"
    if [[ -z "$CHROMIUM_CORE_IMAGE" ]]; then
        _error "No local chromium-core image found for the framework build."
        _error "Build chromium-core first, or ensure a matching local image tag is available."
        exit 1
    fi
    BUILD_ARGS+=(--build-arg "CHROMIUM_CORE_IMAGE=${CHROMIUM_CORE_IMAGE}")
fi
BUILD_ISOLATION="${TILLANDSIAS_BUILD_ISOLATION:-chroot}"
# Reuse the host user namespace for the build container itself. This avoids
# rootless build startup depending on newuidmap on hosts where /run/user/* is
# constrained, while keeping the build runtime native Podman.
BUILD_USERNS="${TILLANDSIAS_BUILD_USERNS:-host}"

_podman_rootless_diagnostic() {
    local probe_log="$1"
    local current_user current_uid current_gid subuid_lines subgid_lines
    current_user="${USER:-$(id -un 2>/dev/null || echo unknown)}"
    current_uid="$(id -u 2>/dev/null || echo unknown)"
    current_gid="$(id -g 2>/dev/null || echo unknown)"
    subuid_lines="$(grep "^${current_user}:" /etc/subuid /etc/subgid 2>/dev/null || true)"

    _error "Rootless Podman namespace setup failed before image build completed."
    _error "The subordinate UID/GID mapping is present and overlap-safe, but the host refused to write the rootless uid_map."
    _error "User: ${current_user} uid=${current_uid} gid=${current_gid}"
    if [[ -n "$subuid_lines" ]]; then
        _info "subuid/subgid entries:"
        printf '%s\n' "$subuid_lines" >&2
    else
        _warn "No subuid/subgid entries found for ${current_user}"
    fi
    _error "Probe log: $probe_log"
}

# Image builds do NOT go through the proxy — SSL bump requires CA trust
# that build containers don't have. Proxy is for runtime containers only.
# @trace spec:user-runtime-lifecycle, spec:init-incremental-builds

BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/tillandsias-build-image.XXXXXX.log")"
trap 'rm -f "$BUILD_LOG"' EXIT

if _verbose_enabled; then
    "$PODMAN" build \
        --no-cache \
        --format docker \
        --isolation "$BUILD_ISOLATION" \
        --userns "$BUILD_USERNS" \
        --tag "$IMAGE_TAG" \
        "${BUILD_ARGS[@]}" \
        "${CACHE_MOUNT_ARGS[@]}" \
        -f "$CONTAINERFILE" \
        "$IMAGE_DIR/"
else
    if ! "$PODMAN" build \
        --no-cache \
        --format docker \
        --isolation "$BUILD_ISOLATION" \
        --userns "$BUILD_USERNS" \
        --tag "$IMAGE_TAG" \
        "${BUILD_ARGS[@]}" \
        "${CACHE_MOUNT_ARGS[@]}" \
        -f "$CONTAINERFILE" \
        "$IMAGE_DIR/" >"$BUILD_LOG" 2>&1; then
        if grep -Eqi 'newuidmap|read-only file system|cannot set up namespace|uid_map' "$BUILD_LOG"; then
            _podman_rootless_diagnostic "$BUILD_LOG"
        fi
        _error "podman build failed for ${IMAGE_TAG}"
        _error "Last build log lines:"
        tail -80 "$BUILD_LOG" >&2 || true
        exit 1
    fi
fi

_apply_alias_tags "$IMAGE_TAG"
_remove_stale_image_tags

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

    _remove_stale_image_tags
    "$PODMAN" image prune -f 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 5: Save hash for staleness detection
# @trace spec:init-incremental-builds
# ---------------------------------------------------------------------------
echo "$CURRENT_HASH" > "$HASH_FILE"

# Clean up any transient tarball emitted by future build backends.
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
if [[ "$USE_HUMAN_ALIASES" == true ]]; then
    _info "Aliases:  ${IMAGE_VERSION_TAG}, ${IMAGE_LATEST_TAG}"
fi
_info "Size:     ${SIZE_DISPLAY}"
_info "Time:     ${BUILD_DURATION}s"
_info "----------------------------------------------"

# Explicit success exit (podman build may return non-zero even on success)
exit 0
