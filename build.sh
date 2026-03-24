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
#   ./build.sh --install            # Release build + install to ~/.local/bin/
#   ./build.sh --remove             # Remove installed binary
#   ./build.sh --wipe               # Remove target/, caches, temp files
#   ./build.sh --toolbox-reset      # Destroy and recreate toolbox
#   ./build.sh --clean --release    # Flags combine
# =============================================================================

set -euo pipefail

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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)        FLAG_RELEASE=true ;;
        --test)           FLAG_TEST=true ;;
        --check)          FLAG_CHECK=true ;;
        --clean)          FLAG_CLEAN=true ;;
        --install)        FLAG_INSTALL=true; FLAG_RELEASE=true ;;
        --remove)         FLAG_REMOVE=true ;;
        --wipe)           FLAG_WIPE=true ;;
        --toolbox-reset)  FLAG_TOOLBOX_RESET=true ;;
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

Install flags:
  --install         Release build + copy binary to ~/.local/bin/
  --remove          Remove installed binary from ~/.local/bin/

Maintenance flags:
  --wipe            Remove target/, ~/.cache/tillandsias/, temp files
  --toolbox-reset   Destroy and recreate the tillandsias toolbox
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

if [[ "$FLAG_REMOVE" == true ]]; then
    rm -f "$INSTALL_BIN" "$INSTALL_DIR/.tillandsias-bin"
    rm -rf "$HOME/.local/lib/tillandsias"
    rm -rf "$HOME/.local/share/tillandsias"

    # Remove desktop launcher and XDG icons
    rm -f "$HOME/.local/share/applications/tillandsias.desktop"
    for size in 32x32 128x128 256x256; do
        rm -f "$HOME/.local/share/icons/hicolor/$size/apps/tillandsias.png"
    done
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    gtk-update-icon-cache "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

    if [[ -f "$INSTALL_BIN" || -f "$INSTALL_DIR/.tillandsias-bin" ]]; then
        _warn "Some files could not be removed"
    else
        _info "Removed tillandsias from $INSTALL_DIR"
    fi
    # If --remove is the only flag, exit
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_WIPE$FLAG_TOOLBOX_RESET" == "falsefalsefalsefalsefalsefalsefalse" ]]; then
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
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_TOOLBOX_RESET" == "falsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

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
    toolbox create "$TOOLBOX_NAME" 2>&1

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
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL" == "falsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# Ensure toolbox exists for any build operation
_toolbox_ensure

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
    # AppImage bundling works in CI (ubuntu with FUSE). For local dev, we
    # produce deb + rpm bundles and the raw binary.
    BUNDLES="deb,rpm"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        BUNDLES="dmg"
    fi

    _step "Building release (bundles: ${BUNDLES})..."

    # Clean old bundles to avoid listing stale versions
    rm -rf "$SCRIPT_DIR/target/release/bundle"

    # Single build: --bundles skips AppImage (needs FUSE, CI handles it).
    # The updater error is expected in toolbox — ignore it.
    _run bash -c "cd '$SCRIPT_DIR' && cargo tauri build --bundles ${BUNDLES}" 2>&1 || {
        # Check if the binary was built despite the bundle error
        if [[ -f "$SCRIPT_DIR/target/release/tillandsias-tray" ]]; then
            _warn "Some bundles failed (updater needs AppImage — CI handles that)"
        else
            _error "Build failed"
            exit 1
        fi
    }
    _info "Release build complete"

    # Show built artifacts
    RELEASE_BIN="$SCRIPT_DIR/target/release/tillandsias-tray"
    BUNDLE_DIR="$SCRIPT_DIR/target/release/bundle"
    if [[ -f "$RELEASE_BIN" ]]; then
        _info "Binary: tillandsias-tray ($(du -h "$RELEASE_BIN" | cut -f1))"
    fi
    if [[ -d "$BUNDLE_DIR" ]]; then
        find "$BUNDLE_DIR" -type f \( -name "*.deb" -o -name "*.rpm" -o -name "*.dmg" -o -name "*.exe" -o -name "*.msi" \) 2>/dev/null | while read -r f; do
            _info "Bundle: $(basename "$f") ($(du -h "$f" | cut -f1))"
        done
    fi

    # Install if requested — standalone, zero host dependencies
    if [[ "$FLAG_INSTALL" == true ]]; then
        if [[ ! -f "$RELEASE_BIN" ]]; then
            _error "Could not find built binary at $RELEASE_BIN"
            exit 1
        fi

        LIB_DIR="$HOME/.local/lib/tillandsias"
        mkdir -p "$INSTALL_DIR" "$LIB_DIR"

        # Bundle shared libraries that aren't on a standard desktop.
        # libappindicator3 is dlopen'd at runtime for tray icon support.
        # These exist inside the toolbox but not on the Silverblue host.
        _step "Bundling runtime libraries from toolbox..."
        for lib in libappindicator3.so.1 libdbusmenu-glib.so.4 libdbusmenu-gtk3.so.4; do
            if _run test -e "/usr/lib64/$lib"; then
                _run cp -L "/usr/lib64/$lib" "$LIB_DIR/$lib"
                _info "  Bundled $lib"
            else
                _warn "  $lib not found in toolbox"
            fi
        done

        # Patch RPATH so the binary finds bundled libs
        if _run command -v patchelf &>/dev/null; then
            _run patchelf --set-rpath "$LIB_DIR" "$RELEASE_BIN"
            _info "Set RPATH to $LIB_DIR"
        fi

        # Create wrapper script that sets LD_LIBRARY_PATH as fallback
        cat > "$INSTALL_BIN" <<WRAPPER
#!/usr/bin/env bash
export LD_LIBRARY_PATH="${LIB_DIR}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "${INSTALL_DIR}/.tillandsias-bin" "\$@"
WRAPPER
        chmod +x "$INSTALL_BIN"

        # Install the actual binary
        cp "$RELEASE_BIN" "$INSTALL_DIR/.tillandsias-bin"
        chmod +x "$INSTALL_DIR/.tillandsias-bin"

        # Build the forge container image via Nix (handles staleness detection)
        if [[ -x "$SCRIPT_DIR/scripts/build-image.sh" ]]; then
            _step "Building forge container image..."
            "$SCRIPT_DIR/scripts/build-image.sh" forge
            _info "Forge image built and loaded"
        else
            _warn "scripts/build-image.sh not found, skipping image build"
        fi

        # Install scripts, image sources, and flake for runtime use
        DATA_DIR="$HOME/.local/share/tillandsias"
        mkdir -p "$DATA_DIR/scripts"

        # Scripts, flake files, and image sources are embedded in the signed
        # binary at compile time (src-tauri/src/embedded.rs). Nothing executable
        # is installed to disk — only icons for the desktop launcher.

        # Copy icons for desktop launcher
        if [[ -d "$SCRIPT_DIR/src-tauri/icons" ]]; then
            mkdir -p "$DATA_DIR/icons"
            cp "$SCRIPT_DIR/src-tauri/icons/32x32.png" "$DATA_DIR/icons/" 2>/dev/null || true
            cp "$SCRIPT_DIR/src-tauri/icons/128x128.png" "$DATA_DIR/icons/" 2>/dev/null || true
            cp "$SCRIPT_DIR/src-tauri/icons/icon.png" "$DATA_DIR/icons/256x256.png" 2>/dev/null || true
        fi

        # Install .desktop launcher and XDG icons
        if [[ "$(uname -s)" == "Linux" ]]; then
            DESKTOP_DIR="$HOME/.local/share/applications"
            ICON_DIR="$HOME/.local/share/icons/hicolor"
            mkdir -p "$DESKTOP_DIR"

            # Install icons into XDG hicolor theme
            for size in 32x32 128x128; do
                if [[ -f "$DATA_DIR/icons/$size.png" ]]; then
                    mkdir -p "$ICON_DIR/$size/apps"
                    cp "$DATA_DIR/icons/$size.png" "$ICON_DIR/$size/apps/tillandsias.png"
                fi
            done
            if [[ -f "$DATA_DIR/icons/256x256.png" ]]; then
                mkdir -p "$ICON_DIR/256x256/apps"
                cp "$DATA_DIR/icons/256x256.png" "$ICON_DIR/256x256/apps/tillandsias.png"
            fi

            # Install .desktop file with correct Exec and absolute Icon path.
            # We use an absolute Icon path because the user-local hicolor dir
            # may lack index.theme on immutable systems (Silverblue), making
            # theme-based lookup unreliable. Packaged installs (deb/rpm) use
            # the theme name since they install into /usr/share.
            ICON_PATH="$ICON_DIR/256x256/apps/tillandsias.png"
            sed -e "s|TILLANDSIAS_BIN|$INSTALL_BIN|g" \
                -e "s|Icon=tillandsias|Icon=$ICON_PATH|g" \
                "$SCRIPT_DIR/assets/tillandsias.desktop" > "$DESKTOP_DIR/tillandsias.desktop"

            # Refresh caches
            gtk-update-icon-cache "$ICON_DIR" 2>/dev/null || true
            update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
            _info "Desktop launcher + icons installed"
        fi

        _info "Installed to $INSTALL_BIN (libs in $LIB_DIR)"
    fi

# Default: debug build (only if no other build flag was set)
elif [[ "$FLAG_TEST$FLAG_CHECK" == "falsefalse" ]]; then
    _step "Building workspace (debug)..."
    _run cargo build --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Debug build complete"
fi
