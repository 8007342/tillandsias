#!/usr/bin/env bash
# Tillandsias Uninstaller
# @trace spec:app-lifecycle
set -euo pipefail

# Seams, for the fixture only (804-bpke). Both default to the shipped values, so
# a real uninstall is unchanged. They exist because this script removes paths
# OUTSIDE $HOME (/usr/local/bin) and branches on uname, so a test that could not
# redirect those two things would have to either skip the macOS arm or delete a
# real installed binary to run.
_uname_s="${TILLANDSIAS_UNINSTALL_FAKE_UNAME:-$(uname -s)}"

IS_MACOS=false
if [[ "$_uname_s" == "Darwin" ]]; then
    IS_MACOS=true
    INSTALL_DIR="${TILLANDSIAS_UNINSTALL_INSTALL_DIR:-/usr/local/bin}"
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
# 804-bpke: on macOS DATA_DIR is the VM home and is preserved without --wipe,
# so it must not be listed as "will be removed" on that path — the preamble is
# the only warning the user gets, and there is no confirmation prompt.
if [[ "$IS_MACOS" == true && "$WIPE" != true ]]; then
    [ -d "$LOG_DIR" ] && echo "    - $LOG_DIR/ (logs)"
else
    [ -d "$DATA_DIR" ] && echo "    - $DATA_DIR/ (app data, including the VM image)"
    [ -d "$CONFIG_DIR" ] && echo "    - $CONFIG_DIR/ (settings)"
    [ -d "$LOG_DIR" ] && echo "    - $LOG_DIR/ (logs)"
fi
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
# Order 804-bpke. On LINUX the six directories above are six distinct XDG
# paths, and DATA_DIR really is bundled data (flake, scripts, images) — cheap
# to reinstall, correct to remove unconditionally. On macOS THREE OF THEM
# COLLAPSE ONTO ONE PATH: LIB_DIR is a subdirectory of DATA_DIR, CONFIG_DIR is
# byte-identical to it, and the same directory is where the VM lives —
# vz.rs's image_root, holding rootfs.img. So this one line, written for the
# Linux meaning, deleted the entire VM.
#
# Measured on a macOS dev host 2026-08-17: DATA_DIR 11.83 GiB actual
# (rootfs.img 11.33 GiB actual / 250 GiB apparent, sparse), against a
# CACHE_DIR of 8 KB. The script then printed "Cache preserved. Use --wipe to
# remove everything." — so the default path destroyed ~11.8 GiB and reported
# preservation, while opting in to "remove everything" added 8 KB. Re-creating
# it costs a ~2.47 GB mandatory re-download (ollama engine payload + model +
# Fedora base) before the guest can serve a token again.
#
# The default therefore preserves the VM on macOS and --wipe removes it, which
# is what the closing message has always promised. Linux behaviour is
# unchanged: there DATA_DIR holds no VM.
if [[ "$IS_MACOS" == true && "$WIPE" != true ]]; then
    echo "  Preserving the VM image in $DATA_DIR (use --wipe to remove it)."
else
    rm -rf "$DATA_DIR"
fi

# ── Remove settings ───────────────────────────────────────────
# On macOS CONFIG_DIR == DATA_DIR, so removing it unconditionally would undo
# the preservation above. Same guard, same reason.
if [[ "$IS_MACOS" == true && "$WIPE" != true ]]; then
    :
else
    rm -rf "$CONFIG_DIR"
fi

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
# 804-bpke: report what this run actually did, per platform and per mode.
if [[ "$IS_MACOS" == true && "$WIPE" != true ]]; then
    echo "    - Logs"
    echo "    - Desktop launcher"
else
    echo "    - App data"
    echo "    - Settings"
    echo "    - Logs"
    echo "    - Desktop launcher"
fi
[[ "$WIPE" == true ]] && echo "    - Cache and container images"
if [[ "$IS_MACOS" == true && "$WIPE" == true ]]; then
    echo "    - VM image ($DATA_DIR)"
fi
echo ""
echo "  Your project files were NOT touched."
# 804-bpke: name what was actually preserved. The old unconditional line said
# "Cache preserved" on a macOS run that had just deleted the VM — the one
# expensive thing on the disk — while the cache it named was 8 KB.
if [[ "$WIPE" != true ]]; then
    if [[ "$IS_MACOS" == true ]]; then
        echo "  VM image, settings and cache preserved. Use --wipe to remove everything."
    else
        echo "  Cache preserved. Use --wipe to remove everything."
    fi
fi
echo ""
