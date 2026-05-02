#!/usr/bin/env bash
# =============================================================================
# Tillandsias — Development Build Script
#
# Single entry point for the entire dev lifecycle. Runs everything inside
# the `tillandsias` toolbox, creating it automatically if needed.
#
# Usage:
#   ./build.sh                      # Debug build
#   ./build.sh --release            # Release build (Tauri bundle)
#   ./build.sh --test               # Run tests
#   ./build.sh --check              # Type-check only
#   ./build.sh --clean              # Clean before building
#   ./build.sh --install            # Build AppImage + install to ~/Applications/
#   ./build.sh --remove             # Remove installed AppImage + symlink
#   ./build.sh --wipe               # Remove target/, caches, temp files
#   ./build.sh --toolbox-reset      # Destroy and recreate toolbox
#   ./build.sh --appimage           # Build AppImage in Ubuntu podman container
#   ./build.sh --clean --release    # Flags combine
# =============================================================================

set -euo pipefail

# @trace spec:dev-build

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLBOX_NAME="$(basename "$SCRIPT_DIR")"
INSTALL_DIR="$HOME/.local/bin"
INSTALL_BIN="$INSTALL_DIR/tillandsias"
CACHE_DIR="$HOME/.cache/tillandsias"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[build]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[build]${NC} $*"; }
_error() { echo -e "${RED}[build]${NC} $*" >&2; }
_step()  { echo -e "${CYAN}[build]${NC} $*"; }

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------
FLAG_RELEASE=false
FLAG_TEST=false
FLAG_CHECK=false
FLAG_CLEAN=false
FLAG_INSTALL=false
FLAG_REMOVE=false
FLAG_WIPE=false
FLAG_TOOLBOX_RESET=false
FLAG_APPIMAGE=false
FLAG_INIT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)        FLAG_RELEASE=true ;;
        --test)           FLAG_TEST=true ;;
        --check)          FLAG_CHECK=true ;;
        --clean)          FLAG_CLEAN=true ;;
        --install)        FLAG_INSTALL=true ;;
        --remove)         FLAG_REMOVE=true ;;
        --wipe)           FLAG_WIPE=true ;;
        --toolbox-reset)  FLAG_TOOLBOX_RESET=true ;;
        --appimage)       FLAG_APPIMAGE=true ;;
        --init)           FLAG_INIT=true ;;
        --help|-h)
            cat <<'EOF'
Tillandsias Development Build Script

Usage: ./build.sh [flags]

Build flags:
  (none)            Debug build (cargo build --workspace)
  --release         Release build (cargo tauri build)
  --test            Run test suite (cargo test --workspace)
  --check           Type-check only (cargo check --workspace)
  --clean           Clean build artifacts before building
  --appimage        Build AppImage in Ubuntu podman container (FUSE-capable)

Install flags:
  --install         Build AppImage + install to ~/Applications/ + symlink to ~/.local/bin/
  --remove          Remove installed AppImage, symlink, and desktop integration

Maintenance flags:
  --wipe            Remove target/, ~/.cache/tillandsias/, temp files
  --toolbox-reset   Destroy and recreate the tillandsias toolbox
  --init            Build all container images with versioned tags (runs on host)
  --help            Show this message

Flags combine: ./build.sh --clean --release --install

The tillandsias toolbox is auto-created on first run with all
build dependencies (GTK, WebKit, Tauri CLI). No manual setup needed.
EOF
            exit 0
            ;;
        *) _error "Unknown flag: $1 (try --help)"; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Standalone operations (don't need toolbox)
# ---------------------------------------------------------------------------

if [[ "$FLAG_INIT" == true ]]; then
    _step "Running tillandsias --init (builds all images with versioned tags)..."
    # Runs on HOST where podman works (not nested in toolbox)
    "$SCRIPT_DIR/target/debug/tillandsias" --init 2>&1
    # Also prune old images
    _step "Pruning old images..."
    podman image prune -f 2>/dev/null || true
    exit 0
fi

if [[ "$FLAG_REMOVE" == true ]]; then
    # Remove AppImage (new install layout)
    rm -f "$HOME/Applications/Tillandsias.AppImage"
    # Remove CLI symlink
    rm -f "$INSTALL_BIN"
    # Remove legacy layout artifacts (old install format)
    rm -f "$INSTALL_DIR/.tillandsias-bin"
    rm -rf "$HOME/.local/lib/tillandsias"
    rm -rf "$HOME/.local/share/tillandsias"

    # Remove desktop launcher and XDG icons
    rm -f "$HOME/.local/share/applications/tillandsias.desktop"
    for size in 32x32 128x128 256x256; do
        rm -f "$HOME/.local/share/icons/hicolor/$size/apps/tillandsias.png"
    done
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

    _info "Removed tillandsias (AppImage, symlink, desktop integration)"
    # If --remove is the only flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_WIPE$FLAG_TOOLBOX_RESET$FLAG_APPIMAGE" == "falsefalsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

if [[ "$FLAG_WIPE" == true ]]; then
    _step "Wiping build artifacts and caches..."
    rm -rf "$SCRIPT_DIR/target"
    rm -rf "$CACHE_DIR"
    # Cargo registry cache inside toolbox is in the host home (shared)
    _info "Removed target/ and $CACHE_DIR"
    # If --wipe is the only remaining flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_TOOLBOX_RESET$FLAG_APPIMAGE" == "falsefalsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# AppImage build (standalone — uses podman Ubuntu container, not toolbox)
# ---------------------------------------------------------------------------

build_appimage() {
    local output_dir="$SCRIPT_DIR/target/release/bundle/appimage"
    local cache_base="$HOME/.cache/tillandsias/appimage-builder"

    _step "Preparing AppImage build directories..."
    mkdir -p "$output_dir"
    mkdir -p "$cache_base"/{cargo-registry,cargo-bin,rustup,apt}

    # Remove old AppImages — avoids "Text file busy" if one is still running.
    # On Linux, rm unlinks the file but running processes keep their fd.
    rm -f "$output_dir"/*.AppImage 2>/dev/null || true

    _info "Output dir:  $output_dir"
    _info "Cache dir:   $cache_base"
    _step "Starting Ubuntu 22.04 podman container for AppImage build..."
    if [[ -f "$cache_base/rustup/settings.toml" ]]; then
        _info "Cached toolchain found — skipping install (~1-2 min build)"
    else
        _warn "First build installs Rust + tauri-cli — expect 10-20 minutes"
    fi

    podman run --rm \
        --device /dev/fuse \
        --cap-add SYS_ADMIN \
        -v "$SCRIPT_DIR:/src:ro,Z" \
        -v "$cache_base/cargo-registry:/root/.cargo/registry:rw,Z" \
        -v "$cache_base/cargo-bin:/root/.cargo/bin:rw,Z" \
        -v "$cache_base/rustup:/root/.rustup:rw,Z" \
        -v "$cache_base/apt:/var/cache/apt:rw,Z" \
        -v "$output_dir:/output:rw,Z" \
        ubuntu:22.04 \
        bash -euo pipefail -c '
set -euo pipefail

# System deps — skip if already installed (cached apt + dpkg state not preserved,
# so we always run apt-get but it will be fast with cached packages)
echo "[appimage] Installing system dependencies..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    libgtk-3-dev \
    libwebkit2gtk-4.1-dev \
    libappindicator3-dev \
    librsvg2-dev \
    libssl-dev \
    fuse \
    libfuse2 \
    curl \
    file \
    ca-certificates \
    2>&1 | tail -3

# Rust — skip install if rustup already cached
if [[ -f /root/.cargo/bin/rustup ]]; then
    echo "[appimage] Rust toolchain cached — skipping install"
    export PATH="/root/.cargo/bin:$PATH"
else
    echo "[appimage] Installing Rust toolchain..."
    curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    export PATH="/root/.cargo/bin:$PATH"
fi

# tauri-cli — skip if already installed
if command -v cargo-tauri &>/dev/null; then
    echo "[appimage] tauri-cli cached — skipping install"
else
    echo "[appimage] Installing tauri-cli..."
    cargo install tauri-cli --version "^2" --locked 2>&1 | tail -3
fi

echo "[appimage] Copying source to writable build directory..."
cp -r /src /build
cd /build

echo "[appimage] Running cargo tauri build (AppImage target)..."
# APPIMAGE_EXTRACT_AND_RUN lets linuxdeploy (itself an AppImage) extract
# to a temp dir instead of requiring FUSE mount — critical for containers.
export APPIMAGE_EXTRACT_AND_RUN=1
# Prefer IPv4 — IPv6 connections to raw.githubusercontent.com hang in containers
echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
# Allow non-zero exit — signing key is only available in CI, the AppImage
# itself is produced before the signing step fails.
cargo tauri build --bundles appimage 2>&1 || true

echo "[appimage] Locating AppImage artifact..."
appimage_file="$(find /build/target/release/bundle/appimage -name "*.AppImage" -type f 2>/dev/null | head -1)"
if [[ -z "$appimage_file" ]]; then
    echo "[appimage] ERROR: No AppImage found in target/release/bundle/appimage/" >&2
    exit 1
fi

echo "[appimage] Copying $(basename "$appimage_file") to output mount..."
rm -f /output/*.AppImage 2>/dev/null || true
cp "$appimage_file" /output/
echo "[appimage] Done: /output/$(basename "$appimage_file")"
'

    # Find the produced AppImage and report it
    local appimage_path
    appimage_path="$(find "$output_dir" -name "*.AppImage" -type f 2>/dev/null | head -1)"
    if [[ -z "$appimage_path" ]]; then
        _error "AppImage build failed — no .AppImage found in $output_dir"
        exit 1
    fi

    chmod +x "$appimage_path"
    _info "AppImage ready: $appimage_path ($(du -h "$appimage_path" | cut -f1))"
}

# ---------------------------------------------------------------------------
# Install AppImage — same layout as the curl installer
# ---------------------------------------------------------------------------

# @trace spec:dev-build
install_appimage() {
    _step "Building AppImage for install..."
    build_appimage

    # Locate the built AppImage
    local appimage_output_dir="$SCRIPT_DIR/target/release/bundle/appimage"
    local appimage_src
    appimage_src="$(find "$appimage_output_dir" -name "*.AppImage" -type f 2>/dev/null | head -1)"
    if [[ -z "$appimage_src" ]]; then
        _error "AppImage build failed — no .AppImage found"
        return 1
    fi

    # Install to ~/Applications/ (same location as curl installer and self-updater)
    local app_dir="$HOME/Applications"
    local app_path="$app_dir/Tillandsias.AppImage"
    mkdir -p "$app_dir"
    cp "$appimage_src" "$app_path"
    chmod +x "$app_path"
    _info "AppImage installed: $app_path ($(du -h "$app_path" | cut -f1))"

    # Create symlink in ~/.local/bin/ for CLI access
    mkdir -p "$INSTALL_DIR"
    ln -sf "$app_path" "$INSTALL_BIN"
    _info "Symlink: $INSTALL_BIN -> $app_path"

    # Build the forge container image with versioned tag (handles staleness detection)
    if [[ -x "$SCRIPT_DIR/scripts/build-image.sh" ]]; then
        local full_version
        full_version="$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')"
        _step "Building forge container image..."
        if ! "$SCRIPT_DIR/scripts/build-image.sh" forge --tag "tillandsias-forge:v${full_version}"; then
            _error "ERROR: forge image build failed — install aborted"
            return 1
        fi
        _info "Forge image built and loaded"
    else
        _warn "scripts/build-image.sh not found, skipping image build"
    fi

    _info "[build] SUCCESS: tillandsias installed and forge image ready"
    _info "Installed. Run 'tillandsias' or launch from your desktop."
    _info "Desktop integration (icons, launcher) is set up on first run."
}

# ---------------------------------------------------------------------------
# Toolbox management
# ---------------------------------------------------------------------------

_toolbox_exists() {
    toolbox list --containers 2>/dev/null | grep -q "^[[:space:]]*[a-f0-9].*${TOOLBOX_NAME}\b"
}

_toolbox_ensure() {
    if _toolbox_exists; then
        return 0
    fi

    _step "Creating toolbox '${TOOLBOX_NAME}'..."
    toolbox create --assumeyes "$TOOLBOX_NAME" 2>&1

    _step "Installing build dependencies..."
    toolbox run -c "$TOOLBOX_NAME" sudo dnf install -y \
        gcc \
        gtk3-devel \
        webkit2gtk4.1-devel \
        libappindicator-gtk3-devel \
        librsvg2-devel \
        openssl-devel \
        pkg-config \
        patchelf \
        2>&1 | tail -3

    _info "Toolbox '${TOOLBOX_NAME}' ready"
}

_toolbox_ensure_tauri_cli() {
    if toolbox run -c "$TOOLBOX_NAME" cargo tauri --version &>/dev/null; then
        return 0
    fi

    _step "Installing tauri-cli (first time, may take a minute)..."
    toolbox run -c "$TOOLBOX_NAME" cargo install tauri-cli --version "^2" 2>&1 | tail -3
    _info "tauri-cli installed"
}

_run() {
    toolbox run -c "$TOOLBOX_NAME" "$@"
}

# Toolbox reset
if [[ "$FLAG_TOOLBOX_RESET" == true ]]; then
    _step "Resetting toolbox '${TOOLBOX_NAME}'..."
    if _toolbox_exists; then
        toolbox rm -f "$TOOLBOX_NAME" 2>&1
        _info "Removed existing toolbox"
    fi
    _toolbox_ensure
    # If --toolbox-reset is the only flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_APPIMAGE" == "falsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# AppImage build (standalone — bypasses toolbox entirely)
if [[ "$FLAG_APPIMAGE" == true ]]; then
    "$SCRIPT_DIR/scripts/bump-version.sh" --bump-build 2>/dev/null || true
    build_appimage
    # If --appimage is the only remaining flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL" == "falsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# Install (builds AppImage via podman, then installs to ~/Applications/)
if [[ "$FLAG_INSTALL" == true ]]; then
    "$SCRIPT_DIR/scripts/bump-version.sh" --bump-build 2>/dev/null || true
    "$SCRIPT_DIR/scripts/generate-traces.sh" 2>/dev/null || true
    if ! install_appimage; then
        _error "[build] ERROR: install failed — check output above for which step failed"
        exit 1
    fi
    exit 0
fi

# Ensure toolbox exists for any build operation
_toolbox_ensure

# ---------------------------------------------------------------------------
# Auto-increment build number on every build (not test/check/clean-only)
# ---------------------------------------------------------------------------
if [[ "$FLAG_TEST$FLAG_CHECK" == "falsefalse" ]]; then
    "$SCRIPT_DIR/scripts/bump-version.sh" --bump-build 2>/dev/null || true
    "$SCRIPT_DIR/scripts/generate-traces.sh" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Build operations
# ---------------------------------------------------------------------------

# Clean
if [[ "$FLAG_CLEAN" == true ]]; then
    _step "Cleaning build artifacts..."
    _run cargo clean --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Clean complete"
fi

# Test
if [[ "$FLAG_TEST" == true ]]; then
    _step "Running tests..."
    _run cargo test --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Tests complete"
fi

# Check
if [[ "$FLAG_CHECK" == true ]]; then
    _step "Type-checking workspace..."
    _run cargo check --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Check complete"
fi

# Release build (via tauri)
if [[ "$FLAG_RELEASE" == true ]]; then
    _toolbox_ensure_tauri_cli

    # Skip AppImage in toolbox — linuxdeploy needs FUSE which isn't available.
    # AppImage bundling works in CI (ubuntu with FUSE) and via --appimage.
    # Linux only distributes via AppImage; no deb/rpm bundles.
    BUNDLES=""
    if [[ "$(uname -s)" == "Darwin" ]]; then
        BUNDLES="dmg"
    fi

    _step "Building release (bundles: ${BUNDLES})..."

    # Clean old bundles to avoid listing stale versions
    rm -rf "$SCRIPT_DIR/target/release/bundle"

    # Single build: --bundles skips AppImage (needs FUSE, CI handles it).
    # The updater error is expected in toolbox — ignore it.
    tauri_build="cd '$SCRIPT_DIR' && cargo tauri build"
    if [[ -n "$BUNDLES" ]]; then
        tauri_build="$tauri_build --bundles $BUNDLES"
    fi
    _run bash -c "$tauri_build" 2>&1 || {
        # Check if the binary was built despite the bundle error
        if [[ -f "$SCRIPT_DIR/target/release/tillandsias" ]]; then
            _warn "Some bundles failed (updater needs AppImage — CI handles that)"
        else
            _error "Build failed"
            exit 1
        fi
    }
    _info "Release build complete"

    # Prune dangling images accumulated during the build
    _step "Pruning dangling podman images..."
    podman image prune -f 2>/dev/null && _info "Dangling images pruned" || true

    # Show built artifacts
    RELEASE_BIN="$SCRIPT_DIR/target/release/tillandsias"
    BUNDLE_DIR="$SCRIPT_DIR/target/release/bundle"
    if [[ -f "$RELEASE_BIN" ]]; then
        _info "Binary: tillandsias ($(du -h "$RELEASE_BIN" | cut -f1))"
    fi
    if [[ -d "$BUNDLE_DIR" ]]; then
        find "$BUNDLE_DIR" -type f \( -name "*.AppImage" -o -name "*.dmg" -o -name "*.exe" -o -name "*.msi" \) 2>/dev/null | while read -r f; do
            _info "Bundle: $(basename "$f") ($(du -h "$f" | cut -f1))"
        done
    fi

    # Note: --install is handled as a standalone operation above (before
    # toolbox setup), using build_appimage() + install_appimage().

# Default: debug build (only if no other build flag was set)
elif [[ "$FLAG_TEST$FLAG_CHECK" == "falsefalse" ]]; then
    _step "Building workspace (debug)..."
    _run cargo build --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Debug build complete"

    # Prune dangling images accumulated during the build
    _step "Pruning dangling podman images..."
    podman image prune -f 2>/dev/null && _info "Dangling images pruned" || true
fi
