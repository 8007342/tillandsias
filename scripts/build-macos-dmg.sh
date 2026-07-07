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
