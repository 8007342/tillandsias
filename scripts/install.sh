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
# Determine the correct asset name based on Tauri's naming convention
RELEASE_URL="https://github.com/${REPO}/releases/latest"

case "$PLATFORM" in
    linux)
        case "$ARCH" in
            x86_64)  ASSET_NAME="Tillandsias_amd64.AppImage" ;;
            aarch64) ASSET_NAME="Tillandsias_aarch64.AppImage" ;;
        esac
        ;;
    macos)
        case "$ARCH" in
            aarch64) ASSET_NAME="Tillandsias_aarch64.dmg" ;;
            x86_64)  ASSET_NAME="Tillandsias_x64.dmg" ;;
        esac
        ;;
esac

# The release uses versioned filenames (e.g., Tillandsias_0.1.35_amd64.AppImage).
# Query the GitHub API for the actual latest release asset URL.
echo "  Finding latest release..."
DOWNLOAD_URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -o "https://[^\"]*${ASSET_NAME%%_*}_[0-9.]*_${ASSET_NAME#*_}" \
    | head -1)

# Fallback: try a simpler pattern match
if [ -z "$DOWNLOAD_URL" ]; then
    # Try matching any asset that ends with the arch-specific suffix
    SUFFIX="${ASSET_NAME#Tillandsias_}"
    DOWNLOAD_URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep -oP '"browser_download_url":\s*"\K[^"]*'"${SUFFIX}" \
        | head -1)
fi

echo "  Downloading from GitHub releases..."

# Create directories
mkdir -p "$INSTALL_DIR" "$LIB_DIR" "$DATA_DIR"

if [ -n "$DOWNLOAD_URL" ] && curl -fsSL -o "/tmp/tillandsias-download" "$DOWNLOAD_URL" 2>/dev/null; then
    if [[ "$PLATFORM" == "linux" ]]; then
        # AppImage — install directly as the binary
        cp "/tmp/tillandsias-download" "$INSTALL_DIR/tillandsias"
        chmod +x "$INSTALL_DIR/tillandsias"
    fi
    rm -f "/tmp/tillandsias-download"
else
    echo "  Download failed."
    echo "  Try downloading manually from: https://github.com/${REPO}/releases/latest"
    echo "  Or build from source: git clone https://github.com/${REPO} && cd tillandsias && ./build.sh --install"
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

# Linux desktop integration
if [[ "$PLATFORM" == "linux" ]]; then
    DESKTOP_DIR="$HOME/.local/share/applications"
    ICON_DIR="$HOME/.local/share/icons/hicolor"

    mkdir -p "$DESKTOP_DIR"

    # Install .desktop file
    sed "s|TILLANDSIAS_BIN|$INSTALL_DIR/tillandsias|g" \
        "$(dirname "$0")/../assets/tillandsias.desktop" > "$DESKTOP_DIR/tillandsias.desktop" 2>/dev/null || \
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
    for size in 32x32 128x128; do
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

# Pre-build container images in the background so they're ready
# when the user runs tillandsias for the first time.
if command -v tillandsias &>/dev/null || [ -x "$INSTALL_DIR/tillandsias" ]; then
    echo "  Building container images in the background..."
    nohup "$INSTALL_DIR/tillandsias" init >/tmp/tillandsias-init.log 2>&1 &
    echo "  (Progress: tail -f /tmp/tillandsias-init.log)"
    echo ""
fi

echo "  Run: tillandsias"
echo ""
