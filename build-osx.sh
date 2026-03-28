#!/usr/bin/env bash
# =============================================================================
# Tillandsias — macOS Build Script
#
# Native build on macOS (Apple Silicon + Intel). No toolbox needed — builds
# directly on the host using Xcode command line tools + Rust.
#
# IMPORTANT: Artifacts are UNSIGNED unless you have a Developer ID configured.
# Production macOS builds go through CI (GitHub Actions on macos-latest).
#
# Usage:
#   ./build-osx.sh                  # Debug build
#   ./build-osx.sh --release        # Release build (Tauri .dmg bundle)
#   ./build-osx.sh --test           # Run test suite
#   ./build-osx.sh --check          # Type-check only
#   ./build-osx.sh --clean          # Clean before building
#   ./build-osx.sh --install        # Release build + install to ~/Applications/
#   ./build-osx.sh --remove         # Remove installed app
#   ./build-osx.sh --wipe           # Remove target/, caches
#   ./build-osx.sh --clean --release  # Flags combine
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
INSTALL_BIN="$INSTALL_DIR/tillandsias"
APP_DEST="$HOME/Applications"
APP_BUNDLE="$APP_DEST/Tillandsias.app"
CACHE_DIR="$HOME/Library/Caches/tillandsias"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[osx-build]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[osx-build]${NC} $*"; }
_error() { echo -e "${RED}[osx-build]${NC} $*" >&2; }
_step()  { echo -e "${CYAN}[osx-build]${NC} $*"; }

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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)   FLAG_RELEASE=true ;;
        --test)      FLAG_TEST=true ;;
        --check)     FLAG_CHECK=true ;;
        --clean)     FLAG_CLEAN=true ;;
        --install)   FLAG_INSTALL=true; FLAG_RELEASE=true ;;
        --remove)    FLAG_REMOVE=true ;;
        --wipe)      FLAG_WIPE=true ;;
        --help|-h)
            cat <<'EOF'
Tillandsias macOS Build Script

Native build on macOS — no toolbox or containers needed.

Usage: ./build-osx.sh [flags]

Build flags:
  (none)            Debug build (cargo build --workspace)
  --release         Release build (cargo tauri build — produces .dmg)
  --test            Run test suite (cargo test --workspace)
  --check           Type-check only (cargo check --workspace)
  --clean           Clean build artifacts before building

Install flags:
  --install         Release build + install .app to ~/Applications/
  --remove          Remove installed app + CLI symlink

Maintenance flags:
  --wipe            Remove target/, ~/Library/Caches/tillandsias/
  --help            Show this message

Flags combine: ./build-osx.sh --clean --release --install

Prerequisites:
  - Xcode Command Line Tools: xcode-select --install
  - Rust: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  - Tauri CLI: cargo install tauri-cli --version "^2"
EOF
            exit 0
            ;;
        *) _error "Unknown flag: $1 (try --help)"; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Platform check
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
    _error "This script is for macOS only. Use ./build.sh for Linux."
    exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  TARGET="aarch64-apple-darwin" ;;
    x86_64) TARGET="x86_64-apple-darwin" ;;
    *)      _error "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Standalone operations
# ---------------------------------------------------------------------------

if [[ "$FLAG_REMOVE" == true ]]; then
    rm -f "$INSTALL_BIN"
    rm -rf "$APP_BUNDLE"
    rm -f "$HOME/Library/LaunchAgents/com.tillandsias.tray.plist"
    _info "Removed Tillandsias from ~/Applications/ and $INSTALL_DIR"
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL$FLAG_WIPE" == "falsefalsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

if [[ "$FLAG_WIPE" == true ]]; then
    _step "Wiping build artifacts and caches..."
    rm -rf "$SCRIPT_DIR/target"
    rm -rf "$CACHE_DIR"
    _info "Removed target/ and $CACHE_DIR"
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN$FLAG_INSTALL" == "falsefalsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Prerequisites check
# ---------------------------------------------------------------------------

_check_prereqs() {
    local missing=false

    if ! command -v cargo &>/dev/null; then
        _error "Rust not found. Install: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        missing=true
    fi

    if ! xcode-select -p &>/dev/null; then
        _error "Xcode Command Line Tools not found. Install: xcode-select --install"
        missing=true
    fi

    if [[ "$missing" == true ]]; then
        exit 1
    fi
}

_ensure_tauri_cli() {
    if cargo tauri --version &>/dev/null; then
        return 0
    fi

    _step "Installing tauri-cli (first time, may take a minute)..."
    cargo install tauri-cli --version "^2" 2>&1 | tail -3
    _info "tauri-cli installed"
}

_check_prereqs

# ---------------------------------------------------------------------------
# Auto-increment build number on every build (not test/check/clean-only)
# ---------------------------------------------------------------------------
if [[ "$FLAG_TEST$FLAG_CHECK" == "falsefalse" ]]; then
    "$SCRIPT_DIR/scripts/bump-version.sh" --bump-build 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Build operations
# ---------------------------------------------------------------------------

# Clean
if [[ "$FLAG_CLEAN" == true ]]; then
    _step "Cleaning build artifacts..."
    cargo clean --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Clean complete"
fi

# Test
if [[ "$FLAG_TEST" == true ]]; then
    _step "Running tests..."
    cargo test --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Tests complete"
fi

# Check
if [[ "$FLAG_CHECK" == true ]]; then
    _step "Type-checking workspace..."
    cargo check --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Check complete"
fi

# Release build (via tauri)
if [[ "$FLAG_RELEASE" == true ]]; then
    _ensure_tauri_cli

    _step "Building release for macOS ($ARCH)..."

    # Clean old bundles to avoid stale artifacts
    rm -rf "$SCRIPT_DIR/target/release/bundle"

    cd "$SCRIPT_DIR"
    cargo tauri build --target "$TARGET" 2>&1 || {
        # The updater signing error is expected without TAURI_SIGNING_PRIVATE_KEY.
        # Check if bundles were actually produced despite the error.
        if [[ -d "$SCRIPT_DIR/target/$TARGET/release/bundle/macos/Tillandsias.app" || \
              -d "$SCRIPT_DIR/target/release/bundle/macos/Tillandsias.app" ]]; then
            _warn "Updater signing failed (expected without TAURI_SIGNING_PRIVATE_KEY)"
        else
            _error "Build failed"
            exit 1
        fi
    }
    _info "Release build complete"

    # Find bundle output — Tauri may use target/<triple>/release or target/release
    BUNDLE_DIR=""
    for candidate in \
        "$SCRIPT_DIR/target/$TARGET/release/bundle" \
        "$SCRIPT_DIR/target/release/bundle"; do
        if [[ -d "$candidate/macos" ]]; then
            BUNDLE_DIR="$candidate"
            break
        fi
    done

    # Show built artifacts
    RELEASE_BIN="$SCRIPT_DIR/target/$TARGET/release/tillandsias-tray"
    [[ ! -f "$RELEASE_BIN" ]] && RELEASE_BIN="$SCRIPT_DIR/target/release/tillandsias-tray"

    if [[ -f "$RELEASE_BIN" ]]; then
        _info "Binary: tillandsias-tray ($(du -h "$RELEASE_BIN" | cut -f1 | xargs))"
    fi
    if [[ -n "$BUNDLE_DIR" ]]; then
        find "$BUNDLE_DIR" -type f \( -name "*.dmg" -o -name "*.app.tar.gz" \) 2>/dev/null | while read -r f; do
            _info "Bundle: $(basename "$f") ($(du -h "$f" | cut -f1 | xargs))"
        done
    fi

    # Install if requested
    if [[ "$FLAG_INSTALL" == true ]]; then
        if [[ -z "$BUNDLE_DIR" || ! -d "$BUNDLE_DIR/macos/Tillandsias.app" ]]; then
            _error "No .app bundle found. Build may have failed."
            exit 1
        fi

        APP_SRC="$BUNDLE_DIR/macos/Tillandsias.app"

        _step "Installing to ~/Applications/..."
        mkdir -p "$APP_DEST" "$INSTALL_DIR"

        # Remove previous install
        rm -rf "$APP_BUNDLE"
        cp -R "$APP_SRC" "$APP_BUNDLE"
        _info "Installed Tillandsias.app to ~/Applications/"

        # Create CLI symlink
        MACOS_BIN="$APP_BUNDLE/Contents/MacOS/tillandsias-tray"
        # Fallback: find the executable if the name differs
        if [[ ! -f "$MACOS_BIN" ]]; then
            MACOS_BIN="$(find "$APP_BUNDLE/Contents/MacOS" -type f -perm +111 | head -1)"
        fi

        if [[ -n "$MACOS_BIN" && -f "$MACOS_BIN" ]]; then
            ln -sf "$MACOS_BIN" "$INSTALL_BIN"
            _info "CLI symlink: $INSTALL_BIN -> $(basename "$MACOS_BIN")"
        else
            _warn "Could not find executable in .app bundle for CLI symlink"
        fi

        # Check PATH
        if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
            echo ""
            _warn "Add to your PATH:"
            _warn "  export PATH=\"$INSTALL_DIR:\$PATH\""
        fi

        echo ""
        _info "Run: open ~/Applications/Tillandsias.app"
        _info "  or: tillandsias (if $INSTALL_DIR is in PATH)"
    fi

    # Unsigned artifact warning (local builds)
    if [[ -z "${APPLE_CERTIFICATE:-}" && -z "${APPLE_SIGNING_IDENTITY:-}" ]]; then
        echo ""
        _warn "╔══════════════════════════════════════════════════════════════╗"
        _warn "║  UNSIGNED BUILD — FOR LOCAL TESTING ONLY                    ║"
        _warn "║                                                              ║"
        _warn "║  This build is not codesigned or notarized. macOS           ║"
        _warn "║  Gatekeeper will block it for other users.                  ║"
        _warn "║                                                              ║"
        _warn "║  To run locally:                                             ║"
        _warn "║    xattr -cr ~/Applications/Tillandsias.app                 ║"
        _warn "║                                                              ║"
        _warn "║  For production builds, use the CI release pipeline:         ║"
        _warn "║    gh workflow run release.yml -f version=X.Y.Z              ║"
        _warn "╚══════════════════════════════════════════════════════════════╝"
        echo ""
    fi

    if [[ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]]; then
        _warn "TAURI_SIGNING_PRIVATE_KEY not set — update signatures not generated"
    fi

# Default: debug build (only if no other build flag was set)
elif [[ "$FLAG_TEST$FLAG_CHECK" == "falsefalse" ]]; then
    _step "Building workspace (debug)..."
    cargo build --workspace --manifest-path "$SCRIPT_DIR/Cargo.toml" 2>&1
    _info "Debug build complete"
fi
