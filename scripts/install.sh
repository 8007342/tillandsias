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
        if curl -fsSL -o "$INSTALL_DIR/tillandsias" "$APPIMAGE_URL"; then
            chmod +x "$INSTALL_DIR/tillandsias"
            INSTALLED=true
            echo "  ✓ Installed AppImage to $INSTALL_DIR/tillandsias"
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
    if [ -n "$DMG_URL" ]; then
        mkdir -p "$INSTALL_DIR"
        echo "  Downloading .dmg..."
        curl -fsSL -o /tmp/Tillandsias.dmg "$DMG_URL"
        echo "  Open /tmp/Tillandsias.dmg and drag to Applications."
        echo "  ✓ Downloaded to /tmp/Tillandsias.dmg"
    else
        echo "  Download failed."
        echo "  Try downloading manually from: ${RELEASE_URL}"
        exit 1
    fi
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

# macOS desktop integration: .app bundle + optional autostart
if [[ "$PLATFORM" == "macos" ]]; then
    APP_DIR="$HOME/Applications/Tillandsias.app"
    mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

    cp "$INSTALL_DIR/tillandsias" "$APP_DIR/Contents/MacOS/"

    # Info.plist
    cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Tillandsias</string>
    <key>CFBundleDisplayName</key>
    <string>Tillandsias</string>
    <key>CFBundleIdentifier</key>
    <string>com.tillandsias.tray</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>tillandsias</string>
    <key>CFBundleIconFile</key>
    <string>tillandsias.icns</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
</dict>
</plist>
PLIST

    # Convert icon (if sips available)
    if command -v sips &>/dev/null && [[ -f "$DATA_DIR/icons/256x256.png" ]]; then
        sips -s format icns "$DATA_DIR/icons/256x256.png" --out "$APP_DIR/Contents/Resources/tillandsias.icns" 2>/dev/null || true
    fi

    echo "  ✓ App bundle installed at ~/Applications/"

    # Autostart via LaunchAgent (disabled by default — controlled by config)
    # To enable, uncomment the block below or set autostart = true in config.toml
    # LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
    # mkdir -p "$LAUNCH_AGENTS_DIR"
    # cat > "$LAUNCH_AGENTS_DIR/com.tillandsias.tray.plist" << LAUNCHAGENT
    # <?xml version="1.0" encoding="UTF-8"?>
    # <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    # <plist version="1.0">
    # <dict>
    #     <key>Label</key>
    #     <string>com.tillandsias.tray</string>
    #     <key>ProgramArguments</key>
    #     <array>
    #         <string>$APP_DIR/Contents/MacOS/tillandsias</string>
    #         <string>--background</string>
    #     </array>
    #     <key>RunAtLoad</key>
    #     <true/>
    #     <key>KeepAlive</key>
    #     <false/>
    # </dict>
    # </plist>
    # LAUNCHAGENT
fi

# Check if PATH includes install dir
if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
    echo "  Add to your PATH:"
    echo "    export PATH=\"$INSTALL_DIR:\$PATH\""
    echo ""
fi

# Pre-build container images in the background (only for non-AppImage installs,
# and only if we have a working terminal — not when piped from curl).
if [ -t 0 ] && [ -x "$INSTALL_DIR/tillandsias" ] && command -v podman &>/dev/null; then
    echo "  Building container images in the background..."
    nohup "$INSTALL_DIR/tillandsias" init >/tmp/tillandsias-init.log 2>&1 &
    echo "  (Progress: tail -f /tmp/tillandsias-init.log)"
    echo ""
fi

echo "  Run: tillandsias"
echo ""
