#!/usr/bin/env bash
# build-local.sh — local build + install for development.
#
# This script is the BASH variant. On Windows, prefer build-local.ps1 — it is
# truly native (no Git Bash window pop, no podman). This bash variant exists
# for parity with Linux/macOS and for users running an existing Git Bash
# session who don't want to switch shells.
#
# Builds tillandsias.exe (debug or --release) and installs to:
#   - Windows: %LOCALAPPDATA%\Tillandsias\tillandsias.exe
#   - Linux/macOS: $LOCALAPPDATA/Tillandsias (rare; use build.sh / build-osx.sh)
#
# Usage: ./build-local.sh [--release]
#
# @trace spec:cross-platform, spec:windows-wsl-runtime
# @cheatsheet runtime/wsl-on-windows.md
# @cheatsheet build/cargo.md

set -euo pipefail

INSTALL_DIR="$LOCALAPPDATA/Tillandsias"
RELEASE=false

if [[ "${1:-}" == "--release" ]]; then
    RELEASE=true
fi

# ── Stop any running tray instance ─────────────────────────────
# Use taskkill.exe — runs natively, no console window pop. Suppresses output
# when no instance is running. (Previously used `powershell.exe -Command
# Stop-Process`, which can flash a brief console window on some systems.)
# @trace spec:cross-platform
case "${OSTYPE:-}" in
    msys*|cygwin*|win32*)
        taskkill.exe //F //IM tillandsias.exe >/dev/null 2>&1 || true
        ;;
    *)
        pkill -f tillandsias 2>/dev/null || true
        ;;
esac
sleep 1

# ── Stage router sidecar ───────────────────────────────────────
# @trace spec:opencode-web-session-otp, spec:cross-platform
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Staging router sidecar..."
"$SCRIPT_DIR/scripts/build-sidecar.sh"

# ── Build the tray binary ──────────────────────────────────────
if $RELEASE; then
    echo "Building release..."
    cargo build --release -p tillandsias
    BIN="target/release/tillandsias.exe"
else
    echo "Building debug..."
    cargo build -p tillandsias
    BIN="target/debug/tillandsias.exe"
fi

VERSION=$(cat VERSION)
echo "Version: $VERSION"

mkdir -p "$INSTALL_DIR"
cp "$BIN" "$INSTALL_DIR/tillandsias.exe"
echo "Installed to $INSTALL_DIR"

# ── Prune stale forge WSL distro ───────────────────────────────
# @trace spec:cross-platform, spec:windows-wsl-runtime
# Windows runtime backend is WSL, NOT podman. The forge "image" is an imported
# WSL distro `tillandsias-forge`; remove it so the next `tillandsias --init`
# imports a fresh one.
#
# Previous versions invoked `podman images | grep tillandsias-forge | xargs
# podman rmi` here — that violated the WSL-only directive and would silently
# fail on Windows hosts without podman installed.
case "${OSTYPE:-}" in
    msys*|cygwin*|win32*)
        echo "Pruning stale forge WSL distro..."
        # Strip nulls from UTF-16 LE output of wsl --list --quiet.
        if wsl.exe --list --quiet 2>/dev/null | tr -d '\0\r' | grep -Fxq "tillandsias-forge"; then
            wsl.exe --unregister "tillandsias-forge" >/dev/null 2>&1 || true
            echo "  removed: tillandsias-forge"
        else
            echo "  no forge distro to prune"
        fi
        ;;
    *)
        # Linux/macOS: still use podman here (this script is rarely run there;
        # build.sh / build-osx.sh are the canonical paths).
        if command -v podman >/dev/null 2>&1; then
            echo "Pruning forge images..."
            podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
                | grep 'tillandsias-forge' \
                | xargs -r -I{} podman rmi {} 2>/dev/null || true
        fi
        ;;
esac

# Clear build hash cache so build-image.sh / wsl-build/* don't skip.
rm -rf "$HOME/.cache/tillandsias/build-hashes/" 2>/dev/null || true
rm -f /tmp/tillandsias-build/build-forge.lock 2>/dev/null || true

echo ""
echo "Done. Run: tillandsias.exe --init"
echo "  or: tillandsias.exe"
