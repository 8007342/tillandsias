#!/usr/bin/env bash
# Tillandsias Linux installer
# Usage: curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
# @trace spec:install-progress, spec:linux-native-portable-executable, spec:ci-release
set -euo pipefail

REPO="8007342/tillandsias"
ASSET="tillandsias-linux-x86_64"
ZEROCLAW_ASSET="tillandsias-zeroclaw-linux-x86_64"
RELEASE_BASE="https://github.com/${REPO}/releases/latest/download"
PATH_MARKER_BEGIN="# >>> tillandsias PATH >>>"
PATH_MARKER_END="# <<< tillandsias PATH <<<"

say() {
    printf '  %s\n' "$*"
}

die() {
    printf '  ERROR: %s\n' "$*" >&2
    exit 1
}

path_has_dir() {
    printf '%s' "${PATH:-}" | tr ':' '\n' | grep -Fx "$1" >/dev/null 2>&1
}

user_bin_candidate_is_safe() {
    case "$1" in
        "$HOME"/*) ;;
        *) return 1 ;;
    esac

    if [ -d "$1" ]; then
        [ -w "$1" ]
    else
        [ -w "$(dirname "$1")" ]
    fi
}

resolve_install_dir() {
    if [ -n "${XDG_BIN_HOME:-}" ]; then
        printf '%s\n' "$XDG_BIN_HOME"
        return
    fi

    mkdir -p "$HOME/.local/bin" 2>/dev/null || true

    for candidate in "$HOME/.local/bin" "$HOME/bin"; do
        if path_has_dir "$candidate" && user_bin_candidate_is_safe "$candidate"; then
            printf '%s\n' "$candidate"
            return
        fi
    done

    IFS=':' read -r -a path_dirs <<< "${PATH:-}"
    for candidate in "${path_dirs[@]}"; do
        if [ -n "$candidate" ] && [ -d "$candidate" ] && user_bin_candidate_is_safe "$candidate"; then
            printf '%s\n' "$candidate"
            return
        fi
    done

    printf '%s\n' "$HOME/.local/bin"
}

append_posix_path_block() {
    profile="$1"
    mkdir -p "$(dirname "$profile")"
    touch "$profile"

    if grep -F "$PATH_MARKER_BEGIN" "$profile" >/dev/null 2>&1; then
        return
    fi

    {
        printf '\n%s\n' "$PATH_MARKER_BEGIN"
        printf 'case ":$PATH:" in\n'
        printf '    *":%s:"*) ;;\n' "$INSTALL_DIR"
        printf '    *) export PATH="%s:$PATH" ;;\n' "$INSTALL_DIR"
        printf 'esac\n'
        printf '%s\n' "$PATH_MARKER_END"
    } >> "$profile"
}

append_fish_path_block() {
    conf="$HOME/.config/fish/conf.d/tillandsias.fish"
    mkdir -p "$(dirname "$conf")"

    if [ -f "$conf" ] && grep -F "$PATH_MARKER_BEGIN" "$conf" >/dev/null 2>&1; then
        return
    fi

    {
        printf '%s\n' "$PATH_MARKER_BEGIN"
        printf 'if not contains -- "%s" $PATH\n' "$INSTALL_DIR"
        printf '    set -gx PATH "%s" $PATH\n' "$INSTALL_DIR"
        printf 'end\n'
        printf '%s\n' "$PATH_MARKER_END"
    } > "$conf"
}

persist_path_setup() {
    if path_has_dir "$INSTALL_DIR"; then
        return 0
    fi

    for profile in "$HOME/.profile" "$HOME/.bashrc"; do
        append_posix_path_block "$profile"
    done

    case "${SHELL:-}" in
        */zsh)
            append_posix_path_block "$HOME/.zprofile"
            append_posix_path_block "$HOME/.zshrc"
            ;;
    esac

    if [ -d "$HOME/.config/fish" ] || [ "${SHELL:-}" != "${SHELL%/fish}" ]; then
        append_fish_path_block
    fi

    return 0
}

cleanup() {
    if [ -n "${TMPDIR_TILLANDSIAS:-}" ] && [ -d "$TMPDIR_TILLANDSIAS" ]; then
        rm -rf "$TMPDIR_TILLANDSIAS"
    fi
}
trap cleanup EXIT

if [[ "${TILLANDSIAS_INSTALL_TEST_MODE:-}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

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

INSTALL_DIR="$(resolve_install_dir)"
INSTALL_PATH="$INSTALL_DIR/tillandsias"

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

ZEROCLAW_TMP="$TMPDIR_TILLANDSIAS/$ZEROCLAW_ASSET"
ZEROCLAW_INSTALL_PATH="$INSTALL_DIR/tillandsias-zeroclaw"
say "Downloading $ZEROCLAW_ASSET..."
if curl -fL --retry 3 --retry-delay 2 -o "$ZEROCLAW_TMP" "$RELEASE_BASE/$ZEROCLAW_ASSET"; then
    chmod 0755 "$ZEROCLAW_TMP"
    mv -f "$ZEROCLAW_TMP" "$ZEROCLAW_INSTALL_PATH"
    say "Installed $ZEROCLAW_INSTALL_PATH"
else
    say "WARNING: tillandsias-zeroclaw not available in this release; ZeroClaw will not work until a release includes it."
fi

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

if ! path_has_dir "$INSTALL_DIR"; then
    echo ""
    persist_path_setup
    say "Configured future shells to include $INSTALL_DIR in PATH."
    say "Open a new terminal, or run now with the absolute path below."
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
say "Running tillandsias --init (sets up local runtime — may take a minute)..."
"$INSTALL_PATH" --init
echo ""
say "Init complete. Launch the tray with:"
if path_has_dir "$INSTALL_DIR"; then
    say "  tillandsias --tray"
else
    say "  $INSTALL_PATH --tray"
    say "  (open a new shell first to get 'tillandsias' on PATH)"
fi
echo ""
