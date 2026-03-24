#!/usr/bin/env bash
# =============================================================================
# Tillandsias — Windows Cross-Compilation Script
#
# Cross-compiles the Rust workspace for x86_64-pc-windows-msvc from Linux
# using cargo-xwin. Runs inside a dedicated `tillandsias-windows` toolbox.
#
# IMPORTANT: Artifacts are UNSIGNED and for local testing/troubleshooting only.
# Production Windows builds must go through CI (GitHub Actions).
#
# Usage:
#   ./build-windows.sh                  # Debug cross-build
#   ./build-windows.sh --release        # Release cross-build (Tauri bundle)
#   ./build-windows.sh --test           # Cross-compile tests (no execution)
#   ./build-windows.sh --check          # Type-check only
#   ./build-windows.sh --clean          # Clean Windows artifacts before build
#   ./build-windows.sh --toolbox-reset  # Destroy and recreate toolbox
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLBOX_NAME="tillandsias-windows"
TARGET="x86_64-pc-windows-msvc"
SDK_MARKER="$HOME/.cache/tillandsias/xwin-sdk-notice-shown"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[win-build]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[win-build]${NC} $*"; }
_error() { echo -e "${RED}[win-build]${NC} $*" >&2; }
_step()  { echo -e "${CYAN}[win-build]${NC} $*"; }

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------
FLAG_RELEASE=false
FLAG_TEST=false
FLAG_CHECK=false
FLAG_CLEAN=false
FLAG_TOOLBOX_RESET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)        FLAG_RELEASE=true ;;
        --test)           FLAG_TEST=true ;;
        --check)          FLAG_CHECK=true ;;
        --clean)          FLAG_CLEAN=true ;;
        --toolbox-reset)  FLAG_TOOLBOX_RESET=true ;;
        --help|-h)
            cat <<'EOF'
Tillandsias Windows Cross-Compilation Script

Cross-compiles for x86_64-pc-windows-msvc from Linux using cargo-xwin.
Artifacts are UNSIGNED — for local testing only. Use CI for production builds.

Usage: ./build-windows.sh [flags]

Build flags:
  (none)            Debug cross-build
  --release         Release cross-build (Tauri NSIS bundle)
  --test            Cross-compile tests (compile check, not executed)
  --check           Type-check only (cargo xwin check)
  --clean           Clean Windows target artifacts before building

Maintenance flags:
  --toolbox-reset   Destroy and recreate the tillandsias-windows toolbox
  --help            Show this message

Flags combine: ./build-windows.sh --clean --release

First run creates the tillandsias-windows toolbox with cross-compilation
dependencies (clang, lld, cargo-xwin). This may take a few minutes.

Note: cargo-xwin downloads Microsoft's CRT and Windows SDK headers on first
use. By using this tool, you accept the Microsoft SDK license terms.
See: https://go.microsoft.com/fwlink/?LinkId=2086102
EOF
            exit 0
            ;;
        *) _error "Unknown flag: $1 (try --help)"; exit 1 ;;
    esac
    shift
done

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

    _step "Installing cross-compilation dependencies..."
    toolbox run -c "$TOOLBOX_NAME" sudo dnf install -y \
        clang \
        lld \
        llvm \
        mingw64-nsis \
        openssl-devel \
        pkg-config \
        2>&1 | tail -5

    _step "Adding Rust Windows target..."
    toolbox run -c "$TOOLBOX_NAME" rustup target add "$TARGET" 2>&1

    _step "Installing cargo-xwin..."
    toolbox run -c "$TOOLBOX_NAME" cargo install cargo-xwin 2>&1 | tail -3

    _info "Toolbox '${TOOLBOX_NAME}' ready"
}

_run() {
    toolbox run -c "$TOOLBOX_NAME" "$@"
}

# Microsoft SDK license notice (shown once)
_sdk_notice() {
    if [[ -f "$SDK_MARKER" ]]; then
        return 0
    fi

    echo ""
    _warn "╔══════════════════════════════════════════════════════════════╗"
    _warn "║  Microsoft SDK Notice                                       ║"
    _warn "║                                                              ║"
    _warn "║  cargo-xwin downloads Microsoft's CRT and Windows SDK        ║"
    _warn "║  headers on first use. By continuing, you accept the         ║"
    _warn "║  Microsoft SDK license terms.                                ║"
    _warn "║                                                              ║"
    _warn "║  License: https://go.microsoft.com/fwlink/?LinkId=2086102   ║"
    _warn "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    mkdir -p "$(dirname "$SDK_MARKER")"
    touch "$SDK_MARKER"
}

# ---------------------------------------------------------------------------
# Toolbox reset
# ---------------------------------------------------------------------------

if [[ "$FLAG_TOOLBOX_RESET" == true ]]; then
    _step "Resetting toolbox '${TOOLBOX_NAME}'..."
    if _toolbox_exists; then
        toolbox rm -f "$TOOLBOX_NAME" 2>&1
        _info "Removed existing toolbox"
    fi
    _toolbox_ensure
    if [[ "$FLAG_RELEASE$FLAG_TEST$FLAG_CHECK$FLAG_CLEAN" == "falsefalsefalsefalse" ]]; then
        exit 0
    fi
fi

# Ensure toolbox exists for any build operation
_toolbox_ensure

# Show SDK notice on first use
_sdk_notice

# ---------------------------------------------------------------------------
# Build operations
# ---------------------------------------------------------------------------

# Clean
if [[ "$FLAG_CLEAN" == true ]]; then
    _step "Cleaning Windows build artifacts..."
    rm -rf "$SCRIPT_DIR/target/$TARGET"
    _info "Clean complete"
fi

# Test (cross-compile only — cannot execute Windows binaries on Linux)
if [[ "$FLAG_TEST" == true ]]; then
    _step "Cross-compiling tests (compile check only, not executed)..."
    _run bash -c "cd '$SCRIPT_DIR' && cargo xwin test --workspace --target $TARGET --no-run" 2>&1
    _info "Test compilation complete (tests cannot be executed on Linux)"
fi

# Check
if [[ "$FLAG_CHECK" == true ]]; then
    _step "Type-checking workspace for Windows target..."
    _run bash -c "cd '$SCRIPT_DIR' && cargo xwin check --workspace --target $TARGET" 2>&1
    _info "Check complete"
fi

# Release build
if [[ "$FLAG_RELEASE" == true ]]; then
    _step "Building release for Windows (unsigned, experimental)..."

    # Clean old bundles to avoid stale artifacts
    rm -rf "$SCRIPT_DIR/target/$TARGET/release/bundle"

    _run bash -c "cd '$SCRIPT_DIR' && cargo xwin build --release --target $TARGET" 2>&1 || {
        _error "Release build failed"
        _warn "Note: Tauri cross-compilation for Windows is experimental."
        _warn "If this fails, use CI (GitHub Actions) for the full Windows build."
        exit 1
    }
    _info "Release build complete"

    # Show built artifacts
    RELEASE_DIR="$SCRIPT_DIR/target/$TARGET/release"
    BUNDLE_DIR="$RELEASE_DIR/bundle"

    if [[ -f "$RELEASE_DIR/tillandsias-tray.exe" ]]; then
        _info "Binary: tillandsias-tray.exe ($(du -h "$RELEASE_DIR/tillandsias-tray.exe" | cut -f1))"
    fi

    if [[ -d "$BUNDLE_DIR" ]]; then
        find "$BUNDLE_DIR" -type f \( -name "*.exe" -o -name "*.msi" -o -name "*.nsis.zip" \) 2>/dev/null | while read -r f; do
            _info "Bundle: $(basename "$f") ($(du -h "$f" | cut -f1))"
        done
    fi

    # Unsigned artifact warning
    echo ""
    _warn "╔══════════════════════════════════════════════════════════════╗"
    _warn "║  UNSIGNED ARTIFACTS — FOR TESTING ONLY                      ║"
    _warn "║                                                              ║"
    _warn "║  These cross-compiled Windows artifacts are NOT signed.      ║"
    _warn "║  They are unsuitable for distribution. Windows SmartScreen   ║"
    _warn "║  will block unsigned executables.                            ║"
    _warn "║                                                              ║"
    _warn "║  For production builds, use the CI release pipeline:         ║"
    _warn "║  gh workflow run release.yml                                 ║"
    _warn "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    if [[ -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]]; then
        _warn "TAURI_SIGNING_PRIVATE_KEY not set — Tauri update signatures not generated"
    fi

# Default: debug build (only if no other build flag was set)
elif [[ "$FLAG_TEST$FLAG_CHECK" == "falsefalse" ]]; then
    _step "Building workspace for Windows (debug)..."
    _run bash -c "cd '$SCRIPT_DIR' && cargo xwin build --workspace --target $TARGET" 2>&1
    _info "Debug build complete"
fi
