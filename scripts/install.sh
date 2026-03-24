#!/usr/bin/env bash
# Tillandsias Installer
# Usage: curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
set -euo pipefail

REPO="8007342/tillandsias"
INSTALL_DIR="$HOME/.local/bin"
LIB_DIR="$HOME/.local/lib/tillandsias"
DATA_DIR="$HOME/.local/share/tillandsias"

# Detect OS and architecture
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$OS" in
    linux)  PLATFORM="linux" ;;
    darwin) PLATFORM="macos" ;;
    *)      echo "Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
    x86_64)  ARCH="x86_64" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo ""
echo "  Tillandsias Installer"
echo "  ====================="
echo ""
echo "  OS:   $PLATFORM"
echo "  Arch: $ARCH"
echo ""

# Determine download URL
# For now: download AppImage on Linux, .app bundle on macOS
ASSET_NAME="tillandsias-${PLATFORM}-${ARCH}"
RELEASE_URL="https://github.com/${REPO}/releases/latest"

echo "  Downloading from GitHub releases..."

# Create directories
mkdir -p "$INSTALL_DIR" "$LIB_DIR" "$DATA_DIR"

# Download the binary (placeholder — actual asset names depend on CI release)
# For now, download and extract the appropriate artifact
DOWNLOAD_URL="${RELEASE_URL}/download/${ASSET_NAME}"
if curl -fsSL -o "/tmp/tillandsias-download" "$DOWNLOAD_URL" 2>/dev/null; then
    cp "/tmp/tillandsias-download" "$INSTALL_DIR/tillandsias"
    chmod +x "$INSTALL_DIR/tillandsias"
    rm -f "/tmp/tillandsias-download"
else
    echo "  Download failed. Release may not be available yet."
    echo "  Build from source: git clone https://github.com/${REPO} && cd tillandsias && ./build.sh --install"
    exit 1
fi

# Install uninstall script
UNINSTALL_URL="${RELEASE_URL}/download/uninstall.sh"
if curl -fsSL -o "$INSTALL_DIR/tillandsias-uninstall" "$UNINSTALL_URL" 2>/dev/null; then
    chmod +x "$INSTALL_DIR/tillandsias-uninstall"
else
    echo "  Warning: Could not download uninstaller. You can uninstall manually by removing:"
    echo "    $INSTALL_DIR/tillandsias"
    echo "    $LIB_DIR"
    echo "    $DATA_DIR"
fi

echo "  ✓ Installed to $INSTALL_DIR/tillandsias"
echo ""

# Check if PATH includes install dir
if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
    echo "  Add to your PATH:"
    echo "    export PATH=\"$INSTALL_DIR:\$PATH\""
    echo ""
fi

echo "  Run: tillandsias"
echo ""
