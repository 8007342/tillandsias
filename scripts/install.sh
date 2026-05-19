#!/usr/bin/env bash
# Tillandsias Linux installer
# Usage: curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
# @trace spec:install-progress, spec:linux-native-portable-executable, spec:ci-release
set -euo pipefail

REPO="8007342/tillandsias"
ASSET="tillandsias-linux-x86_64"
INSTALL_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
INSTALL_PATH="$INSTALL_DIR/tillandsias"
RELEASE_BASE="https://github.com/${REPO}/releases/latest/download"

say() {
    printf '  %s\n' "$*"
}

die() {
    printf '  ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "${TMPDIR_TILLANDSIAS:-}" ] && [ -d "$TMPDIR_TILLANDSIAS" ]; then
        rm -rf "$TMPDIR_TILLANDSIAS"
    fi
}
trap cleanup EXIT

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$OS" in
    linux) ;;
    *) die "unsupported OS: $OS. Tillandsias v0.2 releases are Linux-only." ;;
esac

case "$ARCH" in
    x86_64|amd64) ;;
    *) die "unsupported architecture: $ARCH. This installer ships x86_64 Linux only." ;;
esac

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    die "do not run this installer as root. It installs to the current user's ~/.local/bin."
fi

command -v curl >/dev/null 2>&1 || die "curl is required to download the release asset."

echo ""
say "Tillandsias Installer"
say "====================="
echo ""
say "Target: Linux x86_64"
say "Install path: $INSTALL_PATH"
echo ""

if [ -e /run/ostree-booted ] || command -v rpm-ostree >/dev/null 2>&1; then
    say "Immutable Fedora-style host detected; using userspace install only."
fi

TMPDIR_TILLANDSIAS="$(mktemp -d -t tillandsias-install-XXXXXX)"
BINARY_TMP="$TMPDIR_TILLANDSIAS/$ASSET"
CHECKSUMS_TMP="$TMPDIR_TILLANDSIAS/SHA256SUMS"
CHECKSUM_ONE="$TMPDIR_TILLANDSIAS/SHA256SUMS.$ASSET"

say "Downloading $ASSET..."
curl -fL --retry 3 --retry-delay 2 -o "$BINARY_TMP" "$RELEASE_BASE/$ASSET"

if curl -fsL --retry 3 --retry-delay 2 -o "$CHECKSUMS_TMP" "$RELEASE_BASE/SHA256SUMS"; then
    if grep -E "[[:space:]]${ASSET}$" "$CHECKSUMS_TMP" > "$CHECKSUM_ONE"; then
        if command -v sha256sum >/dev/null 2>&1; then
            say "Verifying SHA256 checksum..."
            (cd "$TMPDIR_TILLANDSIAS" && sha256sum -c "$(basename "$CHECKSUM_ONE")")
        else
            say "sha256sum not found; skipping checksum verification."
        fi
    else
        say "SHA256SUMS did not contain $ASSET; skipping checksum verification."
    fi
else
    say "SHA256SUMS not available; skipping checksum verification."
fi

chmod 0755 "$BINARY_TMP"
mkdir -p "$INSTALL_DIR"
mv -f "$BINARY_TMP" "$INSTALL_PATH"
say "Installed $INSTALL_PATH"

rm -f "$INSTALL_DIR/tillandsias-uninstall" 2>/dev/null || true

if [ -n "${XDG_CURRENT_DESKTOP:-}" ] || [ -n "${DESKTOP_SESSION:-}" ]; then
    DESKTOP_DIR="$HOME/.local/share/applications"
    mkdir -p "$DESKTOP_DIR"
    cat > "$DESKTOP_DIR/tillandsias.desktop" <<DESK
[Desktop Entry]
Name=Tillandsias
Comment=Local development environments that just work
Exec=$INSTALL_PATH --tray
Icon=tillandsias
Terminal=false
Type=Application
Categories=Development;
StartupWMClass=tillandsias
DESK
    say "Desktop launcher installed at $DESKTOP_DIR/tillandsias.desktop"
    update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi

if ! printf '%s' "$PATH" | tr ':' '\n' | grep -Fx "$INSTALL_DIR" >/dev/null 2>&1; then
    echo ""
    say "Add Tillandsias to your PATH:"
    say "export PATH=\"$INSTALL_DIR:\$PATH\""
fi

if command -v podman >/dev/null 2>&1; then
    say "Podman runtime found: $(command -v podman)"
else
    echo ""
    say "Podman is the only Tillandsias runtime dependency and was not found."
    if [ -e /run/ostree-booted ] || command -v rpm-ostree >/dev/null 2>&1; then
        say "On Fedora Silverblue/Kinoite, install Podman with:"
        say "sudo rpm-ostree install podman"
        say "Then reboot."
    elif command -v dnf >/dev/null 2>&1; then
        say "Install with: sudo dnf install podman"
    elif command -v apt-get >/dev/null 2>&1; then
        say "Install with: sudo apt-get install podman"
    elif command -v pacman >/dev/null 2>&1; then
        say "Install with: sudo pacman -S podman"
    else
        say "Install Podman using your distribution's package manager."
    fi
fi

echo ""
say "Run: tillandsias --init --debug"
say "Then: tillandsias --debug --tray"
echo ""
