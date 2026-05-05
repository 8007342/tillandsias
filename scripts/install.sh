#!/usr/bin/env bash
# Tillandsias Installer
# Usage: curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
# @trace spec:install-progress
set -euo pipefail

REPO="8007342/tillandsias"
INSTALL_DIR="$HOME/.local/bin"
LIB_DIR="$HOME/.local/lib/tillandsias"
DATA_DIR="$HOME/.local/share/tillandsias"

# ---------------------------------------------------------------------------
# Chromium pin (host-chromium-on-demand)
# ---------------------------------------------------------------------------
# @trace spec:host-chromium-on-demand
# @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md
#
# These variables pin the Chrome for Testing version we ship the user.
# They are EDITED IN PLACE by scripts/refresh-chromium-pin.sh at every
# Tillandsias release-cut — DO NOT hand-edit the digests.
#
# First-ship pin (verified 2026-04-25 via
# https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json):
#   channels.Stable.version = 148.0.7778.56
#
# The SHA-256 digests below are placeholders — they MUST be replaced by
# `scripts/refresh-chromium-pin.sh` before the first release that ships
# this capability. Until then the install_chromium step in this script
# will run, fail SHA-256 verify, and the curl installer will continue
# without Chromium (the tray surfaces the missing-binary error per the
# detection requirement). Air-gapped users can pre-populate the install
# directory manually or wait for the pin to be authored.
CHROMIUM_VERSION="148.0.7778.56"
CHROMIUM_SHA256_LINUX64=""
CHROMIUM_SHA256_MAC_ARM64=""
CHROMIUM_SHA256_MAC_X64=""
CHROMIUM_SHA256_WIN64=""
export CHROMIUM_VERSION CHROMIUM_SHA256_LINUX64 CHROMIUM_SHA256_MAC_ARM64 \
       CHROMIUM_SHA256_MAC_X64 CHROMIUM_SHA256_WIN64

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

RELEASE_URL="https://github.com/${REPO}/releases/latest"
API_URL="https://api.github.com/repos/${REPO}/releases/latest"

echo "  Finding latest release..."
RELEASE_JSON=$(curl -fsSL "$API_URL" 2>/dev/null || echo "")
if [ -z "$RELEASE_JSON" ]; then
    echo "  Cannot reach GitHub API."
    echo "  Try downloading manually from: ${RELEASE_URL}"
    exit 1
fi

# Helper: find a release asset URL by suffix pattern
# Uses sed instead of grep -P for portability (BSD grep lacks -P)
find_asset() {
    echo "$RELEASE_JSON" | sed -n 's/.*"browser_download_url": *"//p' | sed 's/".*//' | grep "$1" | head -1
}

# ---------------------------------------------------------------------------
# Linux: download AppImage to ~/.local/bin/
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "linux" ]; then
    INSTALLED=false

    # Detect immutable/ostree OS (Silverblue, Kinoite, uBlue, etc.)
    if [ -e /run/ostree-booted ] || command -v rpm-ostree &>/dev/null; then
        echo "  Immutable OS detected (Silverblue/Kinoite/uBlue) — installing to userspace"
        echo ""
    fi

    echo "  Installing AppImage to ~/.local/bin/ (no root required)..."
    APPIMAGE_URL=$(find_asset "linux-x86_64\\.AppImage")
    if [ -z "$APPIMAGE_URL" ]; then
        # Try old versioned name as fallback
        APPIMAGE_URL=$(find_asset "_amd64\\.AppImage")
    fi
    if [ -n "$APPIMAGE_URL" ]; then
        mkdir -p "$INSTALL_DIR"
        echo "  Downloading AppImage..."
        # Download to a temp file first, then atomic rename.
        # Direct write to the target fails with "Text file busy" if the
        # AppImage is currently running (common during reinstall/update).
        TMPFILE="$INSTALL_DIR/.tillandsias-download-$$"
        if curl -fsSL -o "$TMPFILE" "$APPIMAGE_URL"; then
            chmod +x "$TMPFILE"
            # Atomic rename — works even if target is running (Linux unlinks
            # the old inode but running processes keep their file descriptor).
            mv -f "$TMPFILE" "$INSTALL_DIR/tillandsias"
            INSTALLED=true
            echo "  ✓ Installed AppImage to $INSTALL_DIR/tillandsias"
        else
            rm -f "$TMPFILE" 2>/dev/null
        fi
    fi

    if [ "$INSTALLED" = false ]; then
        echo "  Download failed."
        echo "  Try downloading manually from: ${RELEASE_URL}"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# macOS: download .dmg
# ---------------------------------------------------------------------------
if [ "$PLATFORM" = "macos" ]; then
    if [ "$ARCH" = "aarch64" ]; then
        DMG_URL=$(find_asset "macos-aarch64\\.dmg")
        [ -z "$DMG_URL" ] && DMG_URL=$(find_asset "_aarch64\\.dmg")
    else
        DMG_URL=$(find_asset "macos-x86_64\\.dmg")
        [ -z "$DMG_URL" ] && DMG_URL=$(find_asset "_x64\\.dmg")
    fi
    if [ -z "$DMG_URL" ]; then
        echo "  No macOS .dmg found in release."
        echo "  Try downloading manually from: ${RELEASE_URL}"
        exit 1
    fi

    mkdir -p "$INSTALL_DIR"
    echo "  Downloading .dmg..."
    curl -fsSL -o /tmp/Tillandsias.dmg "$DMG_URL"
    echo "  ✓ Downloaded to /tmp/Tillandsias.dmg"

    # Mount the .dmg and copy the .app bundle to ~/Applications/
    echo "  Installing to ~/Applications/..."
    DMG_MOUNT=$(hdiutil attach -nobrowse -readonly /tmp/Tillandsias.dmg 2>/dev/null | tail -1 | awk '{print $NF}')
    if [ -z "$DMG_MOUNT" ]; then
        echo "  Could not mount .dmg. Open /tmp/Tillandsias.dmg manually and drag to Applications."
        exit 1
    fi

    APP_SRC=$(find "$DMG_MOUNT" -maxdepth 1 -name "*.app" -print -quit)
    if [ -z "$APP_SRC" ]; then
        hdiutil detach "$DMG_MOUNT" -quiet 2>/dev/null || true
        echo "  No .app found in .dmg. Open /tmp/Tillandsias.dmg manually and drag to Applications."
        exit 1
    fi

    APP_DEST="$HOME/Applications"
    mkdir -p "$APP_DEST"
    # Remove previous install if present
    rm -rf "$APP_DEST/Tillandsias.app"
    cp -R "$APP_SRC" "$APP_DEST/"
    hdiutil detach "$DMG_MOUNT" -quiet 2>/dev/null || true
    rm -f /tmp/Tillandsias.dmg
    echo "  ✓ Installed Tillandsias.app to ~/Applications/"

    # Create CLI symlink in ~/.local/bin/
    MACOS_BIN="$APP_DEST/Tillandsias.app/Contents/MacOS/tillandsias"
    # Fallback: find the executable if the name differs
    if [ ! -f "$MACOS_BIN" ]; then
        MACOS_BIN="$(find "$APP_DEST/Tillandsias.app/Contents/MacOS" -type f -perm +111 2>/dev/null | head -1)"
    fi
    if [ -n "$MACOS_BIN" ] && [ -f "$MACOS_BIN" ]; then
        ln -sf "$MACOS_BIN" "$INSTALL_DIR/tillandsias"
        echo "  ✓ CLI symlink at $INSTALL_DIR/tillandsias"
    fi

    # ---- Ensure Podman runtime is installed (via MacPorts) ----
    # Tillandsias requires the Podman runtime CLI, NOT Podman Desktop.
    # On macOS we install via MacPorts (not Homebrew) — MacPorts puts podman
    # at /opt/local/bin/podman which find_podman_path() already detects.
    if ! command -v podman &>/dev/null && [ ! -x /opt/local/bin/podman ]; then
        echo ""
        if command -v port &>/dev/null; then
            echo "  Podman runtime not found. Installing via MacPorts..."
            echo "  (You may be prompted for your sudo password)"
            if sudo port install podman; then
                echo "  ✓ Podman runtime installed via MacPorts"
            else
                echo "  ⚠ MacPorts failed to install podman. Run manually:"
                echo "      sudo port install podman"
            fi
        else
            echo "  ⚠ Podman runtime not found and MacPorts is not installed."
            echo ""
            echo "  Tillandsias requires the Podman runtime CLI (not Podman Desktop)."
            echo "  Install MacPorts first:  https://www.macports.org/install.php"
            echo "  Then run:                sudo port install podman"
            echo ""
            echo "  After installing podman, re-run this installer or just launch:"
            echo "    tillandsias"
        fi
    fi

    # ---- Initialize Podman Machine if needed ----
    # Podman on macOS requires a Linux VM (the "machine"). Auto-init + start
    # so the user doesn't have to know about this Podman implementation detail.
    if command -v podman &>/dev/null || [ -x /opt/local/bin/podman ]; then
        PODMAN_BIN="$(command -v podman || echo /opt/local/bin/podman)"
        # Check if a machine exists
        if ! "$PODMAN_BIN" machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then
            echo ""
            echo "  Initializing Podman machine (first-time setup)..."
            if "$PODMAN_BIN" machine init 2>/dev/null; then
                echo "  ✓ Podman machine created"
            else
                echo "  ⚠ Podman machine init failed — you may need to run it manually:"
                echo "    podman machine init"
            fi
        fi
        # Start machine if not running
        if ! "$PODMAN_BIN" machine list --format '{{.Name}} {{.Running}}' 2>/dev/null | grep -q "true"; then
            echo "  Starting Podman machine..."
            if "$PODMAN_BIN" machine start 2>/dev/null; then
                echo "  ✓ Podman machine running"
            else
                echo "  ⚠ Podman machine start failed — start it manually:"
                echo "    podman machine start"
            fi
        fi
    fi
fi

# Uninstall is built into the main binary: tillandsias --uninstall [--wipe]
# Remove legacy uninstaller if it exists from a previous install.
rm -f "$INSTALL_DIR/tillandsias-uninstall" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Chromium download (host-chromium-on-demand)
# ---------------------------------------------------------------------------
# @trace spec:host-chromium-on-demand
#
# Source the install-chromium.sh helper and run install_chromium. The
# helper picks up the CHROMIUM_VERSION + CHROMIUM_SHA256_* variables we
# exported at the top of this script.
#
# When this script is fetched standalone via curl, scripts/install-chromium.sh
# may not be present alongside it. We try a few discovery paths:
#   1. Same directory as this script (release-cut tarball, dev checkout).
#   2. $HOME/.local/share/tillandsias/install-chromium.sh (cached copy).
#   3. Fetch from the release URL (best-effort).
#
# If the helper cannot be located AND SKIP_CHROMIUM_DOWNLOAD is not set,
# we print a one-line advisory and continue — the tray binary will surface
# the missing-binary error on first attach per the detection contract.
INSTALL_CHROMIUM_SH=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo)"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/install-chromium.sh" ]; then
    INSTALL_CHROMIUM_SH="$SCRIPT_DIR/install-chromium.sh"
elif [ -f "$DATA_DIR/install-chromium.sh" ]; then
    INSTALL_CHROMIUM_SH="$DATA_DIR/install-chromium.sh"
fi

if [ -z "$INSTALL_CHROMIUM_SH" ] && [ "${SKIP_CHROMIUM_DOWNLOAD:-}" != "1" ]; then
    # Best-effort fetch from the release that we just installed against.
    REMOTE_HELPER_URL="https://raw.githubusercontent.com/${REPO}/main/scripts/install-chromium.sh"
    TMP_HELPER="$(mktemp -t tillandsias-install-chromium-XXXXXX.sh 2>/dev/null || echo /tmp/tillandsias-install-chromium.sh)"
    if curl -fsSL -o "$TMP_HELPER" "$REMOTE_HELPER_URL"; then
        INSTALL_CHROMIUM_SH="$TMP_HELPER"
    else
        rm -f "$TMP_HELPER" 2>/dev/null || true
    fi
fi

if [ -n "$INSTALL_CHROMIUM_SH" ]; then
    # shellcheck disable=SC1090
    if . "$INSTALL_CHROMIUM_SH" && type -t install_chromium >/dev/null 2>&1; then
        if install_chromium ""; then
            :
        else
            echo "  ! Chromium install step failed — tray will surface a clear error on first attach."
        fi
    fi
elif [ "${SKIP_CHROMIUM_DOWNLOAD:-}" = "1" ]; then
    echo "  Chromium download skipped (SKIP_CHROMIUM_DOWNLOAD=1)."
    echo "  Run later: tillandsias --install-chromium"
else
    echo "  ! install-chromium.sh not found alongside install.sh — Chromium not fetched."
    echo "    Run later: tillandsias --install-chromium"
fi

if [ "$PLATFORM" = "linux" ]; then
    echo "  ✓ Installed to $INSTALL_DIR/tillandsias"
fi
echo ""

# Linux desktop integration
if [[ "$PLATFORM" == "linux" ]]; then
    DESKTOP_DIR="$HOME/.local/share/applications"
    ICON_DIR="$HOME/.local/share/icons/hicolor"

    mkdir -p "$DESKTOP_DIR"

    # Install .desktop file (inline — no external template needed)
    cat > "$DESKTOP_DIR/tillandsias.desktop" << DESK
[Desktop Entry]
Name=Tillandsias
Comment=Local development environments that just work
Exec=$INSTALL_DIR/tillandsias
Icon=tillandsias
Terminal=false
Type=Application
Categories=Development;
StartupWMClass=tillandsias
DESK
    echo "  ✓ Desktop launcher installed"

    # Install icons (use the placeholder green PNGs from src-tauri/icons/)
    for size in 32x32 128x128 256x256; do
        mkdir -p "$ICON_DIR/$size/apps"
        # Copy from data dir if available, otherwise skip
        if [[ -f "$DATA_DIR/icons/$size.png" ]]; then
            cp "$DATA_DIR/icons/$size.png" "$ICON_DIR/$size/apps/tillandsias.png"
        fi
    done

    # Refresh caches
    gtk-update-icon-cache "$ICON_DIR" 2>/dev/null || true
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true

    # Autostart (off by default — user enables via config)
    # When enabled, copy .desktop to autostart dir
    # mkdir -p "$HOME/.config/autostart"
    # cp "$DESKTOP_DIR/tillandsias.desktop" "$HOME/.config/autostart/"
fi

# macOS autostart (disabled by default — controlled by config)
# To enable, uncomment the block below or set autostart = true in config.toml
# if [[ "$PLATFORM" == "macos" ]]; then
#     LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
#     mkdir -p "$LAUNCH_AGENTS_DIR"
#     cat > "$LAUNCH_AGENTS_DIR/com.tillandsias.tray.plist" << LAUNCHAGENT
#     ...
#     LAUNCHAGENT
# fi

# Check if PATH includes install dir
if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
    echo "  Add to your PATH:"
    echo "    export PATH=\"$INSTALL_DIR:\$PATH\""
    echo ""
fi

# On Linux: warn if podman runtime is missing (we don't auto-install on Linux
# because system package managers are the canonical install path — every
# distro has a `podman` package).
if [ "$PLATFORM" = "linux" ] && ! command -v podman &>/dev/null; then
    echo "  ⚠ Podman runtime is not installed."
    echo "    Tillandsias requires the Podman runtime CLI (not Podman Desktop)."
    echo ""
    if command -v dnf &>/dev/null; then
        echo "    Install with: sudo dnf install podman"
    elif command -v apt-get &>/dev/null; then
        echo "    Install with: sudo apt-get install podman"
    elif command -v pacman &>/dev/null; then
        echo "    Install with: sudo pacman -S podman"
    elif command -v zypper &>/dev/null; then
        echo "    Install with: sudo zypper install podman"
    else
        echo "    Install via your distribution's package manager."
    fi
    echo ""
fi

# Pre-build container images in the background (only if we have a working
# terminal — not when piped from curl).
# Detect podman in PATH or at MacPorts location (/opt/local/bin/podman).
if [ -t 0 ] && [ -x "$INSTALL_DIR/tillandsias" ] && \
   { command -v podman &>/dev/null || [ -x /opt/local/bin/podman ]; }; then
    echo "  Building container images in the background..."
    nohup "$INSTALL_DIR/tillandsias" --init >/tmp/tillandsias-init.log 2>&1 &
    echo "  (Progress: tail -f /tmp/tillandsias-init.log)"
    echo ""
fi

# @trace spec:host-chromium-on-demand
# Uninstall hint for the bundled Chromium binary tree (separate from
# `tillandsias --uninstall`, per the spec's `Uninstall path is documented
# one-liner` requirement).
case "$PLATFORM" in
    linux)
        echo "  To remove the bundled Chromium: rm -rf ~/.local/share/tillandsias/chromium/"
        ;;
    macos)
        echo "  To remove the bundled Chromium: rm -rf ~/Library/Application\\ Support/tillandsias/chromium/"
        ;;
esac

echo "  Run: tillandsias"
echo ""
