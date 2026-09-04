#!/usr/bin/env bash
# =============================================================================
# Tillandsias — macOS styled-DMG build script
#
# Wraps dist/Tillandsias.app (built by scripts/build-macos-tray.sh) in a
# drag-to-Applications disk image: custom Tenochtitlan-watermark background
# (images/dmg/dmg-background.png, source SVG alongside), a big "drag to
# Applications" arrow, the app at the left slot and an /Applications drop
# link at the right slot.
#
# The DMG is uploaded with the STABLE name Tillandsias.dmg so the README can
# link https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias.dmg
# without a per-version URL.
#
# Outputs:
#   dist/Tillandsias.dmg
#   (appends its line to dist/SHA256SUMS when that file exists)
#
# Usage:
#   scripts/build-macos-tray.sh && scripts/build-macos-dmg.sh
#
# Prereqs: macOS, create-dmg (auto-installed via brew when missing — CI
# macos-latest runners ship brew). create-dmg drives Finder over AppleScript
# to place icons/background; its built-in retries cover the occasional
# headless-runner Finder hiccup.
#
# @trace spec:macos-tray-build-and-release
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

say() { printf '  %s\n' "$*"; }
die() { printf '  ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "build-macos-dmg.sh must run on macOS"
[[ -d dist/Tillandsias.app ]] || die "dist/Tillandsias.app missing — run scripts/build-macos-tray.sh first"
[[ -f images/dmg/dmg-background.png ]] || die "images/dmg/dmg-background.png missing"

if ! command -v create-dmg >/dev/null 2>&1; then
    say "create-dmg not found; installing via brew"
    brew install create-dmg
fi

# ── Stage: DMG root contains ONLY the app (drop link added by create-dmg) ──
STAGE="dist/dmg-staging"
rm -rf "$STAGE" dist/Tillandsias.dmg
mkdir -p "$STAGE"
cp -R dist/Tillandsias.app "$STAGE/"

# Window 660x440 (title bar + 660x400 content = the background PNG's point
# size: 1320x800 px at 144 dpi). Icon slots must match the arrow drawn in
# images/dmg/dmg-background.svg: app centred at (165,205), drop link at
# (495,205).
say "create-dmg …"
create-dmg \
    --volname "Tillandsias" \
    --background images/dmg/dmg-background.png \
    --window-pos 200 140 \
    --window-size 660 440 \
    --icon-size 128 \
    --icon "Tillandsias.app" 165 205 \
    --hide-extension "Tillandsias.app" \
    --app-drop-link 495 205 \
    --no-internet-enable \
    dist/Tillandsias.dmg "$STAGE"

rm -rf "$STAGE"

# ── Sign + staple the DMG itself (order 935-6fzk) ────────────────────────────
#
# The .app inside is already signed and stapled by build-macos-tray.sh. THE
# CONTAINER WAS NOT, and the container is what the user downloads. An unsigned
# DMG carries the quarantine attribute into a Gatekeeper check that has no
# signature to evaluate on the thing being opened, so the "unidentified
# developer" wall appears before anyone reaches the signed app inside.
#
# Stapling the DMG is the half that matters offline: a ticket stapled to the
# .app travels INSIDE the image, but Gatekeeper assesses the IMAGE first. With
# no ticket on the container that first assessment needs the network, which is
# invisible on any developer machine that has already talked to Apple — the
# same shape as the tray script's stapling-before-packaging note.
#
# Mirrors the tray script's gating exactly, deliberately: identity absent =>
# no-op and the build is byte-for-byte what it was. The release path must not
# change shape on the day a credential appears in someone's keychain.
DMG_SIGN_IDENTITY="${TILLANDSIAS_MACOS_SIGN_IDENTITY:--}"
if [[ "$DMG_SIGN_IDENTITY" != "-" ]]; then
    say "codesign dmg (Developer ID: $DMG_SIGN_IDENTITY)"
    # No --options runtime and no entitlements: a DMG is a container, not code.
    codesign --force --sign "$DMG_SIGN_IDENTITY" --timestamp dist/Tillandsias.dmg >&2 \
        || die "codesign of the DMG failed"
    codesign --verify --strict --verbose=2 dist/Tillandsias.dmg >&2 \
        || die "the DMG signature did not verify after signing"

    if [[ -n "${TILLANDSIAS_NOTARY_KEY:-}" && -n "${TILLANDSIAS_NOTARY_KEY_ID:-}" \
          && -n "${TILLANDSIAS_NOTARY_ISSUER:-}" ]]; then
        command -v xcrun >/dev/null || die "xcrun not in PATH (needed to notarize the DMG)"
        say "notarize dmg: submitting (this waits for Apple's verdict)"
        # A DMG is submitted directly — unlike the .app, it needs no ditto zip.
        xcrun notarytool submit dist/Tillandsias.dmg \
            --key "$TILLANDSIAS_NOTARY_KEY" \
            --key-id "$TILLANDSIAS_NOTARY_KEY_ID" \
            --issuer "$TILLANDSIAS_NOTARY_ISSUER" \
            --wait >&2 \
            || die "DMG notarization FAILED — xcrun notarytool log <submission-id> --key ... for the reason"
        xcrun stapler staple dist/Tillandsias.dmg >&2 || die "stapler staple of the DMG failed"
        # The only check that distinguishes a stapled DMG from a merely signed
        # one. -t open is the DMG assessment; -t exec is for the app.
        spctl -a -vvv -t open --context context:primary-signature dist/Tillandsias.dmg >&2 \
            || die "spctl rejected the stapled DMG"
        say "notarize dmg: accepted and stapled"
    else
        say "notarize dmg: SKIPPED (TILLANDSIAS_NOTARY_KEY/_KEY_ID/_ISSUER not all set)"
        say "                the DMG is signed but NOT notarized — Gatekeeper still blocks a quarantined copy"
    fi
else
    say "codesign dmg: SKIPPED (TILLANDSIAS_MACOS_SIGN_IDENTITY unset) — UNSIGNED container"
    say "              Gatekeeper shows the unidentified-developer wall on a fresh download."
    say "              See plan/issues/macos-signing-research-2026-09-02.md"
fi

# The SHA is taken AFTER signing and stapling, or SHA256SUMS would describe a
# file nobody ships. Both operations rewrite the DMG in place.
DMG_SHA="$(shasum -a 256 dist/Tillandsias.dmg | awk '{print $1}')"
DMG_MB="$(du -m dist/Tillandsias.dmg | cut -f1)"
if [[ -f dist/SHA256SUMS ]]; then
    # Idempotent: drop any stale Tillandsias.dmg line before appending.
    grep -v '  Tillandsias\.dmg$' dist/SHA256SUMS > dist/SHA256SUMS.tmp || true
    mv dist/SHA256SUMS.tmp dist/SHA256SUMS
    printf '%s  Tillandsias.dmg\n' "$DMG_SHA" >> dist/SHA256SUMS
fi

say "built Tillandsias.dmg (${DMG_MB} MiB, sha256 ${DMG_SHA})"
say "dmg: $ROOT/dist/Tillandsias.dmg"
