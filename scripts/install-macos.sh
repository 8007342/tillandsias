#!/usr/bin/env bash
# =============================================================================
# Tillandsias — macOS installer (Apple Silicon, v0.0.1)
#
# Curl-installs Tillandsias.app to /Applications/ (or ~/Applications/ if the
# system path requires sudo). Verifies SHA-256, registers as a Login Item if
# --login-item is passed, CLEARS com.apple.quarantine if the bundle arrived by
# a route that tags downloads, and opens the app.
#
# The curl+tar path never tags: com.apple.quarantine is set by the DOWNLOADING
# application via LaunchServices, and curl/tar are not LaunchServices clients.
# Browsers, Mail, the .dmg and Archive Utility are — so the attribute appears
# only when someone fetched the release by hand. On that route the app is
# ad-hoc signed and not notarized, so Gatekeeper blocks the first launch;
# stripping the attribute is what makes "install" mean install. Right-click ->
# Open no longer bypasses it on macOS 15/26, so the fallback text points at
# System Settings instead.
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
say() { printf '  %s\n' "$*"; }
die() { printf '  ERROR: %s\n' "$*" >&2; exit 1; }

# ── flags ─────────────────────────────────────────────────────────────────
# Release channels (order 305 stable, 621-* unstable):
#   stable   (default) -> /releases/latest/download (newest PROMOTED release)
#   unstable           -> /releases/download/unstable (newest DAILY, rolling)
# Smoke still overrides everything via TILLANDSIAS_RELEASE_BASE.
LOGIN_ITEM=0
# ORDER 1369-sjbc. The DEFAULT is the channel of the release this copy was
# published in: the release job rewrites the next line in the copy it uploads
# to `unstable` (scripts/stage-unstable-installers.sh), because a script cannot
# see the URL it was fetched from. Keep it exactly `DEFAULT_CHANNEL="stable"`;
# the rewrite refuses unless it matches exactly once.
DEFAULT_CHANNEL="stable"
CHANNEL="${TILLANDSIAS_CHANNEL:-$DEFAULT_CHANNEL}"
CHANNEL_SOURCE="default of this installer copy"
[[ -n "${TILLANDSIAS_CHANNEL:-}" ]] && CHANNEL_SOURCE="TILLANDSIAS_CHANNEL"
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --login-item) LOGIN_ITEM=1; shift ;;
        --channel)
            [[ "$#" -ge 2 ]] || die "--channel needs a value"
            CHANNEL="$2"; CHANNEL_SOURCE="--channel"; shift 2
            ;;
        --channel=*) CHANNEL="${1#--channel=}"; CHANNEL_SOURCE="--channel"; shift ;;
        --help|-h)
            cat <<EOF
Usage: install-macos.sh [--login-item] [--channel stable|unstable]

  --login-item      Register Tillandsias as a macOS Login Item so it auto-starts.
  --channel         stable (default) installs the newest promoted release;
                    unstable installs the newest daily build, which is NOT
                    promoted and is expected to break.

  Env:
    TILLANDSIAS_CHANNEL    Same as --channel.
    TILLANDSIAS_VERSION    Pin an exact version (e.g. v0.2.260523.6) instead
                           of installing the latest GitHub release.
EOF
            exit 0
            ;;
        *) die "unknown flag: $1 (try --help)" ;;
    esac
done

case "$CHANNEL" in
    stable)   CHANNEL_BASE="https://github.com/${REPO}/releases/latest/download" ;;
    unstable) CHANNEL_BASE="https://github.com/${REPO}/releases/download/unstable" ;;
    *) die "unknown channel: $CHANNEL (want stable or unstable)" ;;
esac
RELEASE_BASE_LATEST="${TILLANDSIAS_RELEASE_BASE:-$CHANNEL_BASE}"

# ORDER 1369-sjbc. Resolved channel, its source and base URL, printed before
# the gates and before anything is downloaded or swapped. With
# TILLANDSIAS_INSTALL_RESOLVE_ONLY=1 the script stops here, which is how the
# fixture reads it on a non-macOS host.
if [[ -n "${TILLANDSIAS_VERSION:-}" ]]; then
    say "resolved-channel: $CHANNEL ($CHANNEL_SOURCE) base: https://github.com/${REPO}/releases/download/v${TILLANDSIAS_VERSION#v}"
else
    say "resolved-channel: $CHANNEL ($CHANNEL_SOURCE) base: $RELEASE_BASE_LATEST"
fi
[[ "${TILLANDSIAS_INSTALL_RESOLVE_ONLY:-0}" == "1" ]] && exit 0

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
    if [[ -n "${TILLANDSIAS_RELEASE_BASE:-}" ]]; then
        # ORDER 1280-58kq. TILLANDSIAS_RELEASE_BASE overrides CHANNEL_BASE above,
        # so announcing the CHANNEL here describes a resolution that did not
        # happen. Measured on macneo: both the v56.9.19.1 and v56.9.19.2 smokes
        # logged "channel: stable" then "resolving latest release" while pinned
        # to a base whose release GitHub reports as a PRERELEASE — and the stable
        # channel (/releases/latest/download) cannot serve one. The install was
        # correct in both; only these lines were not.
        #
        # The TILLANDSIAS_VERSION arm one branch up already announces its own pin
        # ("pinned to v<version>"), so this is a missing case rather than a
        # missing idea: every path that bypasses channel resolution should say
        # which path it took instead.
        say "channel: pinned ${TILLANDSIAS_RELEASE_BASE}"
    else
        say "channel: $CHANNEL"
        if [[ "$CHANNEL" == "unstable" ]]; then
            say "  !! UNSTABLE channel — newest daily build, NOT promoted to stable."
            say "     Expect breakage. Re-run without --channel for the stable build."
        fi
        say "resolving latest release"
    fi
fi

# ── temp workspace ───────────────────────────────────────────────────────
TMP="$(mktemp -d -t tillandsias-install.XXXXXX)"
# ORDER 1281-pgit: the trap also restores the app if we die mid-swap, so an
# interrupted install never leaves $DEST absent while a backup exists.
_INSTALL_STAGE=""
_INSTALL_RESTORE_FROM=""
_INSTALL_RESTORE_TO=""
_install_cleanup() {
    if [[ -n "$_INSTALL_RESTORE_TO" && ! -d "$_INSTALL_RESTORE_TO" \
          && -n "$_INSTALL_RESTORE_FROM" && -d "$_INSTALL_RESTORE_FROM" ]]; then
        mv "$_INSTALL_RESTORE_FROM" "$_INSTALL_RESTORE_TO" 2>/dev/null || true
    fi
    [[ -n "$_INSTALL_STAGE" ]] && rm -rf "$_INSTALL_STAGE"
    rm -rf "$TMP"
}
trap _install_cleanup EXIT INT TERM HUP PIPE

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
if pgrep -x tillandsias-tray >/dev/null 2>&1; then
    say "stopping running tillandsias-tray"
    osascript -e 'tell application "tillandsias-tray" to quit' 2>/dev/null || true
    # Give it 5s to quit cleanly, then SIGTERM, then SIGKILL.
    for _ in 1 2 3 4 5; do
        pgrep -x tillandsias-tray >/dev/null 2>&1 || break
        sleep 1
    done
    pkill -TERM -x tillandsias-tray 2>/dev/null || true
    sleep 1
    pkill -KILL -x tillandsias-tray 2>/dev/null || true
fi

# ── extract BESIDE the destination, then swap ────────────────────────────
# ORDER 1281-pgit. The previous order was: rm -rf the old backup, mv the LIVE
# app aside, then extract. That left $DEST EMPTY for the whole duration of the
# extraction, so an installer interrupted at any point in between — a signal, a
# full disk, a closing laptop — left the host with NO application and NO backup.
# Measured on macneo 2026-09-19: the installer was killed by SIGPIPE mid-swap
# and /Applications held neither Tillandsias.app nor Tillandsias.app.bak.
#
# Now: extract into a staging directory on the SAME filesystem, and only then
# perform the swap as two adjacent renames. The destructive step (removing the
# previous backup) happens LAST, after the new app is already in place.
STAGE="$(mktemp -d "${INSTALL_DIR}/.tillandsias-install.XXXXXX")" \
    || die "could not create a staging directory in $INSTALL_DIR"
_INSTALL_STAGE="$STAGE"

say "extracting to $DEST"
tar -xzf "$TMP/$ASSET_NAME" -C "$STAGE"
NEW_APP="$STAGE/${DEST##*/}"
[[ -d "$NEW_APP" ]] || die "extraction did not produce ${DEST##*/}"

BACKUP="${DEST}.bak"
if [[ -d "$DEST" ]]; then
    # Keep the PREVIOUS backup until the swap has succeeded; it is the only
    # other copy on disk while the renames are in flight.
    PREV_BACKUP=""
    if [[ -e "$BACKUP" ]]; then
        PREV_BACKUP="${BACKUP}.prev.$$"
        mv "$BACKUP" "$PREV_BACKUP"
    fi
    say "backing up existing app to ${BACKUP##*/}"
    # From here until the new app is in place, $DEST does not exist. The EXIT
    # trap below restores the backup if anything interrupts us, so a trappable
    # death cannot leave the host with nothing. SIGKILL cannot be trapped; the
    # window is two adjacent renames on one filesystem, and the backup survives
    # it in every case.
    _INSTALL_RESTORE_FROM="$BACKUP"
    _INSTALL_RESTORE_TO="$DEST"
    mv "$DEST" "$BACKUP"
fi

mv "$NEW_APP" "$DEST" || die "could not move the new app into $DEST"
_INSTALL_RESTORE_FROM=""
_INSTALL_RESTORE_TO=""
[[ -d "$DEST" ]] || die "swap did not produce $DEST"

# The new app is in place; only now is it safe to drop the older backup.
[[ -n "${PREV_BACKUP:-}" ]] && rm -rf "$PREV_BACKUP"
rm -rf "$STAGE"
_INSTALL_STAGE=""

# ── ORDER 1286-4437: reset the local state, with the NEW app in place ────
# By default, and SYNCHRONOUSLY, before the tray is launched below. Two
# reasons it sits exactly here and not elsewhere:
#   * AFTER the swap, because the binary that reprovisions must be the new
#     one — resetting first would reprovision with the outgoing version;
#   * BEFORE `open -a`, because the reset refuses to run against a live tray
#     (order 277) and this is the last point where none is running.
# NO INSTALLER-LEVEL OPT-OUT. TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 is the one
# and only escape hatch and the tray reads it itself; a second variable here
# was proposed, agreed by three hosts and approved before anyone read the
# source, and tillandsias-core's guard documents why it must not exist.
# TILLANDSIAS_RESET_KEEP_MODELS is passed through by the environment for the
# same reason: it narrows the reset, it does not skip it.
say "resetting local state (--reset-state); TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 skips the destruction"
set +e
"$DEST/Contents/MacOS/tillandsias-tray" --reset-state
RESET_EXIT=$?
set -e
# Fail LOUD. A failed reset has already destroyed the local state and left the
# guest unprovisioned; carrying on to `open -a` would hand the operator a tray
# booting against nothing, with the installer's last word being "Installed".
[[ -n "${RESET_EXIT:-}" && $RESET_EXIT -eq 0 ]] || \
    die "tillandsias-tray --reset-state failed (exit ${RESET_EXIT:-<empty>}); the local state may be cleared and the guest unprovisioned — re-run this installer"

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
say ""
say "Installed: $DEST"
# curl downloads never carry com.apple.quarantine, so this installer's
# curl+tar path launches cleanly on first open — Gatekeeper's first-launch
# assessment only fires on quarantined bundles (browser/DMG/zip provenance,
# or a tarball whose members carry the xattr: bsdtar restores archived
# xattrs). Probe the installed bundle and only warn when the warning is
# true (order 421). Note `xattr -p` also exits non-zero if xattr itself is
# unavailable; in that unlikely case we stay quiet and Gatekeeper's own
# dialog still guides the user.
if xattr -p com.apple.quarantine "$DEST" >/dev/null 2>&1; then
    # STRIP IT RATHER THAN LECTURE ABOUT IT. Reaching this branch means the
    # bundle arrived by a route that tags downloads — a browser, the .dmg, or
    # Archive Utility, which propagates the xattr to extracted contents where
    # `tar(1)` does not. The user asked for an install; removing the attribute
    # IS the install on that route.
    #
    # `-dr`, never `-cr`: the latter strips EVERY xattr from every bundle
    # member, which is a much larger hammer than this problem needs.
    #
    # This changes nothing about the signature — quarantine is a filesystem
    # attribute, not part of the code signature — which is why the verify
    # below is a real check and not a formality.
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

    if xattr -p com.apple.quarantine "$DEST" >/dev/null 2>&1; then
        # Still tagged: almost always a permissions problem in /Applications.
        # Say the CURRENT recovery, not the old one — right-click->Open stopped
        # bypassing this on macOS 15 Sequoia and 26 Tahoe, where the first
        # dialog offers only Done / Move to Trash.
        cat <<EOF

  Could not clear the quarantine attribute on:
      $DEST

  Gatekeeper will block the first launch. Either re-run with sudo, or:

      xattr -dr com.apple.quarantine "$DEST"

  If macOS still refuses (it shows only "Done" / "Move to Trash"):
      System Settings -> Privacy & Security -> scroll to Security
      -> "Open Anyway" -> authenticate.
  On macOS 15+ that button appears only for a short window after the
  refusal, so open the app once first, then go looking for it.

EOF
    else
        say "cleared com.apple.quarantine (arrived via a download that tags files)"
    fi
fi

# The signature must still verify after any of the above. Quarantine removal
# cannot damage it, so a failure here means something else is wrong with the
# bundle — a truncated download, or a tarball that lost bits in transit — and
# it is far better to say so now than to let the app fail obscurely at launch.
if ! codesign --verify --deep --strict "$DEST" 2>/dev/null; then
    say "WARNING: codesign --verify failed for $DEST"
    say "         The bundle may be incomplete; re-run the installer."
fi
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
        # ASCII only next to expansions: macOS system bash 3.2 folds a
        # multibyte char abutting $VAR into the variable NAME, and under
        # set -u the script dies "DIAG_PIN…: unbound variable" AFTER a
        # successful install (live: v0.3.260716.7 smoke, 2026-07-16).
        say "installed: version=${DIAG_VERSION} pin=${DIAG_PIN}"
    fi
else
    die "$TRAY_BIN missing or not executable; tarball extracted but binary is broken"
fi

say "Launching Tillandsias (--init / VM provisioning runs automatically on first launch)..."
open -a "$DEST" || say "warning: open returned non-zero — right-click Tillandsias.app in $INSTALL_DIR and choose Open"
say "Tray started. Look for the Tillandsias icon in the menu bar."
say "(Provisioning runs in the background on first launch — no extra step needed.)"

# ── PENDING ACTIONS (order 1380-zmpi, design section 9.4) ───────────────────
# Nothing is pending on macOS today: the VM's swap lives inside the guest
# (1377-hcnv) and needs no host step. "PENDING: none" is printed rather than
# omitted, because silence and "nothing pending" produce the same bytes. A
# future pending step appends its line to the call below. The marker lines are
# what scripts/test-installers-print-pending-banner.sh cuts on; keep them.
# BEGIN-PENDING-BANNER
pending_banner() {
    _rule="================================================================"
    printf '\n%s\n  PENDING ACTIONS\n%s\n' "$_rule" "$_rule"
    if [[ "$#" -eq 0 ]]; then
        printf '  PENDING: none\n'
    else
        for _p in "$@"; do printf '  >> %s\n' "$_p"; done
    fi
    printf '%s\n\n' "$_rule"
}
pending_banner
# END-PENDING-BANNER
