#!/usr/bin/env bash
# =============================================================================
# Tillandsias — macOS installer (Apple Silicon, v0.0.1)
#
# Curl-installs Tillandsias.app to /Applications/ (or ~/Applications/ if the
# system path requires sudo). Verifies SHA-256, registers as a Login Item if
# --login-item is passed, prints the Gatekeeper right-click-Open hint (v0.0.1
# is ad-hoc signed, not notarized), and opens the app.
#
# Usage:
#   curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install-macos.sh | bash
#   curl -fsSL …/install-macos.sh | bash -s -- --login-item
#   TILLANDSIAS_VERSION=v0.2.260523.6 curl … | bash       # pin a version
#
# @trace spec:macos-tray-build-and-release
# =============================================================================

set -euo pipefail

REPO="8007342/tillandsias"
ASSET_PREFIX="tillandsias-tray-"
ASSET_SUFFIX="-macos-arm64.tar.gz"
RELEASE_BASE_LATEST="https://github.com/${REPO}/releases/latest/download"

say() { printf '  %s\n' "$*"; }
die() { printf '  ERROR: %s\n' "$*" >&2; exit 1; }

# ── flags ─────────────────────────────────────────────────────────────────
LOGIN_ITEM=0
for arg in "$@"; do
    case "$arg" in
        --login-item) LOGIN_ITEM=1 ;;
        --help|-h)
            cat <<EOF
Usage: install-macos.sh [--login-item]

  --login-item   Register Tillandsias as a macOS Login Item so it auto-starts.

  Env:
    TILLANDSIAS_VERSION    Pin an exact version (e.g. v0.2.260523.6) instead
                           of installing the latest GitHub release.
EOF
            exit 0
            ;;
        *) die "unknown flag: $arg (try --help)" ;;
    esac
done

# ── gates ─────────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" ]] || die "install-macos.sh must run on macOS"
[[ "$(uname -m)" == "arm64"  ]] \
    || die "Tillandsias v0.0.1 requires Apple Silicon (uname -m must be arm64; this host is $(uname -m))"

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( MACOS_MAJOR >= 14 )) \
    || die "Tillandsias requires macOS 14.0 or later (this host: $(sw_vers -productVersion))"

# ── resolve version ──────────────────────────────────────────────────────
if [[ -n "${TILLANDSIAS_VERSION:-}" ]]; then
    VERSION="${TILLANDSIAS_VERSION#v}"
    BASE="https://github.com/${REPO}/releases/download/v${VERSION}"
    say "pinned to v${VERSION}"
else
    BASE="$RELEASE_BASE_LATEST"
    say "resolving latest release"
fi

# ── temp workspace ───────────────────────────────────────────────────────
TMP="$(mktemp -d -t tillandsias-install.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ── download ─────────────────────────────────────────────────────────────
SHA_URL="${BASE}/SHA256SUMS"
say "fetching SHA256SUMS"
curl -fsSL "$SHA_URL" -o "$TMP/SHA256SUMS" \
    || die "could not download $SHA_URL"

# Find the macOS tarball name from SHA256SUMS. v0.0.1: only one entry
# matches the prefix/suffix, but be robust.
ASSET_NAME="$(awk -v p="$ASSET_PREFIX" -v s="$ASSET_SUFFIX" '$2 ~ p && $2 ~ s {print $2; exit}' "$TMP/SHA256SUMS")"
[[ -n "$ASSET_NAME" ]] \
    || die "no ${ASSET_PREFIX}*${ASSET_SUFFIX} entry in SHA256SUMS"
say "asset: $ASSET_NAME"

ASSET_URL="${BASE}/${ASSET_NAME}"
say "downloading $ASSET_URL"
curl -fSL --progress-bar "$ASSET_URL" -o "$TMP/$ASSET_NAME"

# ── verify SHA-256 ───────────────────────────────────────────────────────
EXPECTED="$(grep -F "  $ASSET_NAME" "$TMP/SHA256SUMS" | awk '{print $1}')"
ACTUAL="$(shasum -a 256 "$TMP/$ASSET_NAME" | awk '{print $1}')"
if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    die "SHA-256 mismatch: expected $EXPECTED, got $ACTUAL"
fi
say "sha256: ok ($EXPECTED)"

# ── install location ─────────────────────────────────────────────────────
INSTALL_DIR="/Applications"
if ! [[ -w "$INSTALL_DIR" ]]; then
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
    say "/Applications not writable; using $INSTALL_DIR"
fi

DEST="$INSTALL_DIR/Tillandsias.app"

# ── stop running tray + back up existing ─────────────────────────────────
if pgrep -f tillandsias-tray >/dev/null 2>&1; then
    say "stopping running tillandsias-tray"
    osascript -e 'tell application "tillandsias-tray" to quit' 2>/dev/null || true
    # Give it 5s to quit cleanly, then SIGTERM, then SIGKILL.
    for _ in 1 2 3 4 5; do
        pgrep -f tillandsias-tray >/dev/null 2>&1 || break
        sleep 1
    done
    pkill -TERM -f tillandsias-tray 2>/dev/null || true
    sleep 1
    pkill -KILL -f tillandsias-tray 2>/dev/null || true
fi

if [[ -d "$DEST" ]]; then
    BACKUP="${DEST}.bak"
    rm -rf "$BACKUP"
    say "backing up existing app to ${BACKUP##*/}"
    mv "$DEST" "$BACKUP"
fi

# ── extract ──────────────────────────────────────────────────────────────
say "extracting to $DEST"
tar -xzf "$TMP/$ASSET_NAME" -C "$INSTALL_DIR"
[[ -d "$DEST" ]] || die "extraction did not produce $DEST"

# ── login item (opt-in) ──────────────────────────────────────────────────
if (( LOGIN_ITEM )); then
    say "registering as Login Item (--login-item)"
    osascript <<EOF >/dev/null 2>&1 || say "warning: could not register Login Item"
tell application "System Events"
    if not (exists login item "Tillandsias") then
        make new login item at end with properties {path:"$DEST", hidden:false}
    end if
end tell
EOF
fi

# ── Gatekeeper hint + launch ────────────────────────────────────────────
cat <<EOF

  Installed: $DEST

  Tillandsias v0.0.1 is ad-hoc signed. On first launch macOS Gatekeeper
  may block it with "Tillandsias is from an unidentified developer."

  To bypass:
      Finder → $INSTALL_DIR → right-click Tillandsias.app → Open → Open

  After the first bypass, double-clicking works normally.

EOF
say "launching $DEST"
open -a "$DEST" || say "warning: open returned non-zero — try the right-click Open above"
