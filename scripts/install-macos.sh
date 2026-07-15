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
# Default: stable channel (/releases/latest). Smoke overrides via
# TILLANDSIAS_RELEASE_BASE to pin a specific daily prerelease (order 305).
RELEASE_BASE_LATEST="${TILLANDSIAS_RELEASE_BASE:-https://github.com/${REPO}/releases/latest/download}"

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
SHA_URL="${BASE}/SHA256SUMS-macos"
say "fetching SHA256SUMS-macos"
curl -fsSL "$SHA_URL" -o "$TMP/SHA256SUMS-macos" \
    || die "could not download $SHA_URL"

# Find the macOS tarball name from SHA256SUMS-macos. v0.0.1: only one entry
# matches the prefix/suffix, but be robust.
ASSET_NAME="$(awk -v p="$ASSET_PREFIX" -v s="$ASSET_SUFFIX" '$2 ~ p && $2 ~ s {print $2; exit}' "$TMP/SHA256SUMS-macos")"
[[ -n "$ASSET_NAME" ]] \
    || die "no ${ASSET_PREFIX}*${ASSET_SUFFIX} entry in SHA256SUMS-macos"
say "asset: $ASSET_NAME"

ASSET_URL="${BASE}/${ASSET_NAME}"
say "downloading $ASSET_URL"
curl -fSL --progress-bar "$ASSET_URL" -o "$TMP/$ASSET_NAME"

# ── verify SHA-256 ───────────────────────────────────────────────────────
EXPECTED="$(grep -F "  $ASSET_NAME" "$TMP/SHA256SUMS-macos" | awk '{print $1}')"
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
# ── post-install sanity check ───────────────────────────────────────────
# Invoke the bundled `--diagnose --json` to confirm the install bits
# are sound (version baked, manifest pin present, the binary can run)
# BEFORE asking AppKit to launch the GUI. Failure here means the
# tarball was corrupted in transit or the codesign step ran on the
# wrong file — the installer should surface that immediately rather
# than the user staring at a never-appearing menubar icon.
#
# Exit codes:
#   0 — image-root provisioned (only on re-install over an already-
#       provisioned tray; first install is "2 / not provisioned" + ok).
#   2 — degraded but bits intact (the expected first-install state).
#   1 — hard failure (binary missing, codesign broken).
say "verifying installed binary via --diagnose --json"
TRAY_BIN="$DEST/Contents/MacOS/tillandsias-tray"
if [[ -x "$TRAY_BIN" ]]; then
    set +e
    DIAG_JSON="$("$TRAY_BIN" --diagnose --json 2>/dev/null)"
    DIAG_EXIT=$?
    set -e
    if [[ $DIAG_EXIT -eq 1 ]]; then
        die "tillandsias-tray --diagnose --json hard-failed (exit 1); install bits broken"
    fi
    # Best-effort breadcrumb: surface version + manifest pin so the
    # user has a one-liner for support if the GUI doesn't appear.
    # Skip silently if jq isn't installed.
    if command -v jq >/dev/null 2>&1; then
        DIAG_VERSION="$(echo "$DIAG_JSON" | jq -r '.version' 2>/dev/null || echo '?')"
        DIAG_PIN="$(echo "$DIAG_JSON" | jq -r '.manifest_pin_aarch64_qcow2 // "?"' 2>/dev/null)"
        say "installed: version=$DIAG_VERSION pin=$DIAG_PIN…"
    fi
else
    die "$TRAY_BIN missing or not executable; tarball extracted but binary is broken"
fi

say "Launching Tillandsias (--init / VM provisioning runs automatically on first launch)..."
open -a "$DEST" || say "warning: open returned non-zero — try the right-click Open above"
say "Tray started. Look for the Tillandsias icon in the menu bar."
say "(Provisioning runs in the background on first launch — no extra step needed.)"
