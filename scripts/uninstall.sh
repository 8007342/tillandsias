#!/usr/bin/env bash
# Tillandsias Uninstaller
set -euo pipefail

INSTALL_DIR="$HOME/.local/bin"
LIB_DIR="$HOME/.local/lib/tillandsias"
DATA_DIR="$HOME/.local/share/tillandsias"
CACHE_DIR="$HOME/.cache/tillandsias"

WIPE=false
[[ "${1:-}" == "--wipe" ]] && WIPE=true

echo ""
echo "  Tillandsias Uninstaller"
echo "  ======================"
echo ""

# Remove binaries
rm -f "$INSTALL_DIR/tillandsias" "$INSTALL_DIR/tillandsias-uninstall"
echo "  ✓ Removed binary"

# Remove bundled libraries
rm -rf "$LIB_DIR"
echo "  ✓ Removed libraries"

# Remove bundled data (flake, scripts, images)
rm -rf "$DATA_DIR"
echo "  ✓ Removed data"

# Linux desktop cleanup
rm -f "$HOME/.local/share/applications/tillandsias.desktop"
rm -f "$HOME/.local/share/icons/hicolor/32x32/apps/tillandsias.png"
rm -f "$HOME/.local/share/icons/hicolor/128x128/apps/tillandsias.png"
rm -f "$HOME/.local/share/icons/hicolor/256x256/apps/tillandsias.png"
rm -f "$HOME/.config/autostart/tillandsias.desktop"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
echo "  ✓ Removed desktop launcher"

# macOS desktop cleanup
rm -rf "$HOME/Applications/Tillandsias.app"
rm -f "$HOME/Library/LaunchAgents/com.tillandsias.tray.plist"

if [[ "$WIPE" == true ]]; then
    # Remove cache (container images, opencode, openspec, secrets)
    rm -rf "$CACHE_DIR"
    echo "  ✓ Removed cache and secrets"

    # Remove container images
    podman rmi tillandsias-forge:latest 2>/dev/null || true
    podman rmi tillandsias-web:latest 2>/dev/null || true
    echo "  ✓ Removed container images"

    # Remove builder toolbox
    toolbox rm -f tillandsias-builder 2>/dev/null || true
    echo "  ✓ Removed builder toolbox"
fi

echo ""
echo "  Tillandsias uninstalled."
[[ "$WIPE" == true ]] && echo "  All data wiped." || echo "  Cache preserved. Use --wipe to remove everything."
echo ""
