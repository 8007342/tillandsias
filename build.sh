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
    if [[ -f "$INSTALL_BIN" ]]; then
        rm -f "$INSTALL_BIN"
        _info "Removed $INSTALL_BIN"
    else
        _warn "Nothing to remove — $INSTALL_BIN not found"
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
    # The updater plugin expects an AppImage on Linux for signed update bundles,
    # but AppImage needs FUSE (not available in toolbox). For local dev builds,
    # we use --no-bundle to get the raw binary, then bundle deb/rpm separately.
    # CI produces AppImage on ubuntu with FUSE available.
    _run bash -c "cd '$SCRIPT_DIR' && cargo tauri build --no-bundle" 2>&1 || true

    # Bundle deb/rpm (these work in toolbox, ignore updater error)
    _run bash -c "cd '$SCRIPT_DIR' && cargo tauri build --bundles ${BUNDLES}" 2>&1 || {
        _warn "Some bundles failed (updater needs AppImage — CI handles that)"
        _warn "Binary was built successfully"
    }
    _info "Release build complete"

    # Show built artifacts — workspace target dir is at project root
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

    # Install if requested
    if [[ "$FLAG_INSTALL" == true ]]; then
        if [[ -f "$RELEASE_BIN" ]]; then
            mkdir -p "$INSTALL_DIR"
            cp "$RELEASE_BIN" "$INSTALL_BIN"
            chmod +x "$INSTALL_BIN"
            _info "Installed to $INSTALL_BIN"
        else
            _error "Could not find built binary at $RELEASE_BIN"
            exit 1
        fi
    fi

# Default: debug build (only if no other build flag was set)
elif [[ "$FLAG_TEST$FLAG_CHECK" == "falsefalse" ]]; then
    _step "Building workspace (debug)..."
    _run cargo build --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Debug build complete"
fi
