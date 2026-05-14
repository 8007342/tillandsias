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

SERVICE_USER="tillandsias"
SERVICE_GROUP="tillandsias"
SERVICE_HOME="/var/lib/tillandsias"
SYSTEMD_USER_UNIT_DIR="/etc/systemd/user"
SYSUSERS_DIR="/etc/sysusers.d"
TMPFILES_DIR="/etc/tmpfiles.d"
IS_ROOT=false
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    IS_ROOT=true
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
if [[ "$IS_ROOT" == true ]]; then
    [ -f "$SYSTEMD_USER_UNIT_DIR/tillandsias.service" ] && echo "    - $SYSTEMD_USER_UNIT_DIR/tillandsias.service (systemd user service)"
    [ -f "$SYSUSERS_DIR/tillandsias.conf" ] && echo "    - $SYSUSERS_DIR/tillandsias.conf (service account sysusers entry)"
    [ -f "$TMPFILES_DIR/tillandsias.conf" ] && echo "    - $TMPFILES_DIR/tillandsias.conf (service account tmpfiles entry)"
    [ -d "$SERVICE_HOME" ] && echo "    - $SERVICE_HOME/ (service account home/state)"
    [ -f "/usr/local/bin/tillandsias" ] && echo "    - /usr/local/bin/tillandsias (system binary)"
fi
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

# ── Remove service account runtime ────────────────────────────
if [[ "$IS_ROOT" == true ]]; then
    if command -v runuser >/dev/null 2>&1; then
        SERVICE_UID="$(id -u "$SERVICE_USER" 2>/dev/null || echo "")"
        if [[ -n "$SERVICE_UID" ]]; then
            runuser -u "$SERVICE_USER" -- env HOME="$SERVICE_HOME" XDG_RUNTIME_DIR="/run/user/$SERVICE_UID" \
                systemctl --user disable --now tillandsias.service podman.socket 2>/dev/null || true
        fi
    fi
    loginctl disable-linger "$SERVICE_USER" 2>/dev/null || true
fi

# ── Remove service-account unit files and policy ──────────────
if [[ "$IS_ROOT" == true ]]; then
    rm -f "$SYSTEMD_USER_UNIT_DIR/tillandsias.service"
    rm -f "$SYSUSERS_DIR/tillandsias.conf"
    rm -f "$TMPFILES_DIR/tillandsias.conf"
fi

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

if [[ "$IS_ROOT" == true ]]; then
    rm -f "/usr/local/bin/tillandsias" "/usr/local/bin/tillandsias-uninstall"
    userdel -r "$SERVICE_USER" 2>/dev/null || true
    groupdel "$SERVICE_GROUP" 2>/dev/null || true
    rm -rf "$SERVICE_HOME"
fi

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
