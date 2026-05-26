#!/usr/bin/env bash
# =============================================================================
# Tillandsias — macOS tray build script
#
# Builds tillandsias-macos-tray for Apple Silicon, assembles the .app bundle
# with Info.plist substitution + ad-hoc codesign + virtualization entitlement,
# tars it into dist/, writes SHA256SUMS, and prints a one-line summary.
#
# Outputs:
#   dist/Tillandsias.app                                            (signed bundle)
#   dist/tillandsias-tray-<version>-macos-arm64.tar.gz              (release artifact)
#   dist/SHA256SUMS                                                 (line per artifact)
#
# Usage:
#   scripts/build-macos-tray.sh
#
# Prereqs: macOS (Apple Silicon), Rust toolchain with aarch64-apple-darwin
# target (= host triple on Apple Silicon), codesign, tar, shasum.
#
# @trace spec:macos-tray-build-and-release, spec:macos-native-tray
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

say() { printf '  %s\n' "$*"; }
die() { printf '  ERROR: %s\n' "$*" >&2; exit 1; }

# ── 1. Host arch gate ────────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" ]] || die "build-macos-tray.sh must run on macOS (uname -s is $(uname -s))"
[[ "$(uname -m)" == "arm64"  ]] || die "build host must be Apple Silicon (uname -m must be arm64; got $(uname -m))"

# ── 2. Toolchain check ───────────────────────────────────────────────────
command -v cargo    >/dev/null || die "cargo not in PATH (install Rust: https://rustup.rs)"
command -v codesign >/dev/null || die "codesign not in PATH (install Xcode Command Line Tools)"
command -v shasum   >/dev/null || die "shasum not in PATH"

# Apple Silicon is the host triple, so 'cargo build --release' is enough; an
# explicit --target aarch64-apple-darwin produces the same binary but adds
# a different output path. We use --release without --target.

# ── 3. Resolve version ──────────────────────────────────────────────────
[[ -f VERSION ]] || die "VERSION file not found at $ROOT/VERSION"
VERSION="$(cat VERSION | tr -d '[:space:]')"
VERSION_SHORT="$(echo "$VERSION" | cut -d. -f1-2)"
MIN_MACOS="14.0"
say "version: $VERSION  short: $VERSION_SHORT  min_macos: $MIN_MACOS"

# ── 4. Build ────────────────────────────────────────────────────────────
say "cargo build --release -p tillandsias-macos-tray …"
cargo build --release -p tillandsias-macos-tray >&2

BIN_PATH="$ROOT/target/release/tillandsias-tray"
[[ -x "$BIN_PATH" ]] || die "expected binary at $BIN_PATH after release build"

# ── 5. Assemble .app bundle ─────────────────────────────────────────────
DIST="$ROOT/dist"
APP="$DIST/Tillandsias.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH" "$APP/Contents/MacOS/tillandsias-tray"

# Substitute Info.plist template.
TEMPLATE="$ROOT/crates/tillandsias-macos-tray/assets/Info.plist.template"
[[ -f "$TEMPLATE" ]] || die "Info.plist.template missing at $TEMPLATE"
sed \
    -e "s/@VERSION@/${VERSION}/g" \
    -e "s/@VERSION_SHORT@/${VERSION_SHORT}/g" \
    -e "s/@MIN_MACOS@/${MIN_MACOS}/g" \
    "$TEMPLATE" > "$APP/Contents/Info.plist"

# Icon: convert PDF → ICNS if iconutil + tooling is available; else copy the
# PDF as a placeholder. Real branding-quality .icns is post-v0.0.1.
ICON_SRC="$ROOT/crates/tillandsias-macos-tray/assets/icon.pdf"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APP/Contents/Resources/icon.pdf"
    # Info.plist references CFBundleIconFile=icon (no extension); macOS
    # auto-picks .icns or .pdf. PDF works for the menubar's text rendition.
fi

# ── 6. Ad-hoc codesign with entitlements ────────────────────────────────
ENTITLEMENTS="$ROOT/crates/tillandsias-macos-tray/assets/Tillandsias.entitlements"
[[ -f "$ENTITLEMENTS" ]] || die "Tillandsias.entitlements missing at $ENTITLEMENTS"
say "codesign (ad-hoc) with $ENTITLEMENTS"
codesign --force --sign - \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    "$APP" >&2

# Verify
say "verify signature"
codesign --verify --deep --strict --verbose=2 "$APP" >&2

# Check entitlement present
ENTITLE_DUMP="$(codesign -d --entitlements - "$APP" 2>&1 || true)"
echo "$ENTITLE_DUMP" | grep -q 'com.apple.security.virtualization' \
    || die "com.apple.security.virtualization entitlement NOT present after sign"

# ── 7. Tarball + SHA256 ─────────────────────────────────────────────────
TAR_NAME="tillandsias-tray-${VERSION}-macos-arm64.tar.gz"
TAR_PATH="$DIST/$TAR_NAME"
( cd "$DIST" && tar -czf "$TAR_NAME" Tillandsias.app )

SHA="$(shasum -a 256 "$TAR_PATH" | awk '{print $1}')"
echo "${SHA}  ${TAR_NAME}" > "$DIST/SHA256SUMS"

# ── 8. Summary ──────────────────────────────────────────────────────────
SIZE_BYTES="$(stat -f%z "$TAR_PATH")"
SIZE_MB="$(echo "scale=2; $SIZE_BYTES / 1048576" | bc)"
say "built ${TAR_NAME} (${SIZE_MB} MiB, sha256 ${SHA})"
say "bundle: $APP"
say "tarball: $TAR_PATH"
