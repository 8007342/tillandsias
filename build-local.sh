#!/usr/bin/env bash
# Local Windows build + install for development.
# Builds debug, installs to %LOCALAPPDATA%\Tillandsias, prunes old forge images.
#
# Usage: ./build-local.sh [--release]
#
# @trace spec:cross-platform

set -euo pipefail

INSTALL_DIR="$LOCALAPPDATA/Tillandsias"
RELEASE=false

if [[ "${1:-}" == "--release" ]]; then
    RELEASE=true
fi

# Kill running instance — try both legacy and current binary names
powershell.exe -Command "Stop-Process -Name tillandsias-tray -Force -ErrorAction SilentlyContinue" 2>/dev/null || true
powershell.exe -Command "Stop-Process -Name tillandsias -Force -ErrorAction SilentlyContinue" 2>/dev/null || true
sleep 1

# Build (the binary was renamed from tillandsias-tray to tillandsias in v0.1.157;
# the package name is now `tillandsias` per src-tauri/Cargo.toml).
if $RELEASE; then
    echo "Building release..."
    cargo build --release -p tillandsias
    BIN="target/release/tillandsias.exe"
else
    echo "Building debug..."
    cargo build -p tillandsias
    BIN="target/debug/tillandsias.exe"
fi

# Read version from the built binary
VERSION=$(cat VERSION)
echo "Version: $VERSION"

# Install — copy under both names so legacy shortcuts/scripts keep working.
mkdir -p "$INSTALL_DIR"
cp "$BIN" "$INSTALL_DIR/tillandsias.exe"
cp "$BIN" "$INSTALL_DIR/tillandsias-tray.exe"
echo "Installed to $INSTALL_DIR"

# Remove ALL forge images so the fresh build triggers a forge rebuild on launch
echo "Pruning forge images..."
podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep 'tillandsias-forge' \
    | xargs -r -I{} podman rmi {} 2>/dev/null || true

# Clear build hash cache so build-image.sh doesn't skip
rm -rf "$HOME/.cache/tillandsias/build-hashes/" 2>/dev/null || true
rm -f /tmp/tillandsias-build/build-forge.lock 2>/dev/null || true

echo ""
echo "Done. Run: tillandsias-tray.exe --init"
echo "  or: tillandsias-tray.exe"
