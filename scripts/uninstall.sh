#!/usr/bin/env bash
# Tillandsias Uninstaller
# @trace spec:app-lifecycle
set -euo pipefail

if [[ "$(uname -s)" == "Darwin" ]]; then
    INSTALL_DIR="/usr/local/bin"
    LIB_DIR="$HOME/Library/Application Support/tillandsias/lib"
    DATA_DIR="$HOME/Library/Application Support/tillandsias"
    CONFIG_DIR="$HOME/Library/Application Support/tillandsias"
    LOG_DIR="$HOME/Library/Logs/tillandsias"
    CACHE_DIR="$HOME/Library/Caches/tillandsias"
else
    INSTALL_DIR="$HOME/.local/bin"
    LIB_DIR="$HOME/.local/lib/tillandsias"
    DATA_DIR="$HOME/.local/share/tillandsias"
    CONFIG_DIR="$HOME/.config/tillandsias"
    LOG_DIR="$HOME/.local/state/tillandsias"
    CACHE_DIR="$HOME/.cache/tillandsias"
fi

WIPE=false
[[ "${1:-}" == "--wipe" ]] && WIPE=true

echo ""
echo "  Tillandsias Uninstaller"
echo "  ======================"
echo ""

# ── Show what will be removed ──────────────────────────────────
echo "  Tillandsias will remove the following:"
echo ""
[ -f "$INSTALL_DIR/tillandsias" ] && echo "    - $INSTALL_DIR/tillandsias (app binary)"
[ -f "$INSTALL_DIR/tillandsias-uninstall" ] && echo "    - $INSTALL_DIR/tillandsias-uninstall (uninstaller)"
[ -d "$LIB_DIR" ] && echo "    - $LIB_DIR/ (libraries)"
[ -d "$DATA_DIR" ] && echo "    - $DATA_DIR/ (app data)"
[ -d "$CONFIG_DIR" ] && echo "    - $CONFIG_DIR/ (settings)"
[ -d "$LOG_DIR" ] && echo "    - $LOG_DIR/ (logs)"
if [[ "$WIPE" == true ]]; then
    [ -d "$CACHE_DIR" ] && echo "    - $CACHE_DIR/ (cache)"
    echo "    - tillandsias-forge:* container images"
    echo "    - tillandsias-web:* container images"
fi
echo ""
echo "  Your project files will NOT be touched."
echo ""

# ── Remove binaries ───────────────────────────────────────────
rm -f "$INSTALL_DIR/tillandsias" "$INSTALL_DIR/tillandsias-uninstall"

# ── Remove bundled libraries ──────────────────────────────────
rm -rf "$LIB_DIR"

# ── Remove bundled data (flake, scripts, images) ──────────────
rm -rf "$DATA_DIR"

# ── Remove settings ───────────────────────────────────────────
rm -rf "$CONFIG_DIR"

# ── Remove logs ───────────────────────────────────────────────
rm -rf "$LOG_DIR"

# ── Linux desktop cleanup ─────────────────────────────────────
rm -f "$HOME/.local/share/applications/tillandsias.desktop"
rm -f "$HOME/.local/share/icons/hicolor/32x32/apps/tillandsias.png"
rm -f "$HOME/.local/share/icons/hicolor/128x128/apps/tillandsias.png"
rm -f "$HOME/.local/share/icons/hicolor/256x256/apps/tillandsias.png"
rm -f "$HOME/.config/autostart/tillandsias.desktop"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

# ── macOS desktop cleanup ─────────────────────────────────────
rm -rf "$HOME/Applications/Tillandsias.app"
rm -f "$HOME/Library/LaunchAgents/com.tillandsias.tray.plist"

if [[ "$WIPE" == true ]]; then
    # Remove cache (container images, opencode, openspec, secrets)
    rm -rf "$CACHE_DIR"

    # Remove all versioned forge and web images
    podman images --format '{{.Repository}}:{{.Tag}}' | grep '^tillandsias-forge:' | xargs -r podman rmi 2>/dev/null || true
    podman images --format '{{.Repository}}:{{.Tag}}' | grep '^tillandsias-web:' | xargs -r podman rmi 2>/dev/null || true

    # Remove cached nix build output
    rm -rf "$CACHE_DIR/build-output" 2>/dev/null || true
fi

# ── Report ─────────────────────────────────────────────────────
echo ""
echo "  Uninstall complete. The following were removed:"
echo ""
echo "    - App binary"
echo "    - Libraries"
echo "    - App data"
echo "    - Settings"
echo "    - Logs"
echo "    - Desktop launcher"
[[ "$WIPE" == true ]] && echo "    - Cache and container images"
echo ""
echo "  Your project files were NOT touched."
[[ "$WIPE" != true ]] && echo "  Cache preserved. Use --wipe to remove everything."
echo ""
