#!/usr/bin/env bash
# =============================================================================
# Tillandsias — Version Bump Script
#
# Reads VERSION file and updates all version locations atomically.
# Version format: Major.Minor.YYMMDD.Build (CalVer with build counter)
#   - Major: Contract version (user-driven for breaking changes)
#   - Minor: Phase/compatibility (user-driven for phases)
#   - YYMMDD: Release date (calendar versioning, always monotonic with time)
#   - Build: Local build counter (auto-increments on every build, merges via LUB)
#
# Usage:
#   ./scripts/bump-version.sh              # Sync all files to VERSION
#   ./scripts/bump-version.sh --bump-build # Increment build number (daily counter)
#   ./scripts/bump-version.sh --new-day    # New calendar day, reset build to 1
#   ./scripts/bump-version.sh --bump-minor # Increment minor version, reset day to today
# =============================================================================

set -euo pipefail

# @trace spec:versioning

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"

if [[ ! -f "$VERSION_FILE" ]]; then
    echo "ERROR: VERSION file not found at $VERSION_FILE" >&2
    exit 1
fi

# Read current version (CalVer format: Major.Minor.YYMMDD.Build)
FULL_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
IFS='.' read -r MAJOR MINOR YYMMDD BUILD <<< "$FULL_VERSION"

# Get today's date in YYMMDD format
TODAY_YYMMDD="$(date +%y%m%d)"

# Handle flags
case "${1:-}" in
    --bump-build)
        # Increment build number for current day
        if [[ "$YYMMDD" != "$TODAY_YYMMDD" ]]; then
            echo "NOTICE: Date has changed ($YYMMDD → $TODAY_YYMMDD), resetting build to 1"
            YYMMDD="$TODAY_YYMMDD"
            BUILD=1
        else
            BUILD=$((BUILD + 1))
        fi
        FULL_VERSION="${MAJOR}.${MINOR}.${YYMMDD}.${BUILD}"
        echo "$FULL_VERSION" > "$VERSION_FILE"
        echo "Bumped build: $FULL_VERSION"
        ;;
    --new-day)
        # Manual new-day transition (rarely needed; usually auto-detected by --bump-build)
        YYMMDD="$TODAY_YYMMDD"
        BUILD=1
        FULL_VERSION="${MAJOR}.${MINOR}.${YYMMDD}.${BUILD}"
        echo "$FULL_VERSION" > "$VERSION_FILE"
        echo "New day transition: $FULL_VERSION"
        ;;
    --bump-minor)
        # Increment minor version (e.g., 0.1 → 0.2), reset date and build
        MINOR=$((MINOR + 1))
        YYMMDD="$TODAY_YYMMDD"
        BUILD=1
        FULL_VERSION="${MAJOR}.${MINOR}.${YYMMDD}.${BUILD}"
        echo "$FULL_VERSION" > "$VERSION_FILE"
        echo "Bumped minor version: $FULL_VERSION"
        ;;
    "")
        # Sync mode: only print current version (no changes)
        if [[ "$YYMMDD" != "$TODAY_YYMMDD" ]]; then
            echo "WARNING: Version date ($YYMMDD) is behind today ($TODAY_YYMMDD)"
        fi
        echo "Syncing version: $FULL_VERSION"
        ;;
    *)
        echo "Usage: $0 [--bump-build|--new-day|--bump-minor]" >&2
        exit 1
        ;;
esac

# Derive 3-part semver for Cargo/Tauri (using YYMMDD as patch version)
SEMVER="${MAJOR}.${MINOR}.${YYMMDD}"

# Update all Cargo.toml files (workspace members)
for cargo_toml in \
    "$ROOT/crates/tillandsias-core/Cargo.toml" \
    "$ROOT/crates/tillandsias-scanner/Cargo.toml" \
    "$ROOT/crates/tillandsias-podman/Cargo.toml" \
    "$ROOT/src-tauri/Cargo.toml"; do
    if [[ -f "$cargo_toml" ]]; then
        # Replace version = "x.y.z" in [package] section (first occurrence)
        # BSD sed (macOS) requires '' after -i; GNU sed does not.
        if sed --version 2>/dev/null | grep -q GNU; then
            sed -i "0,/^version = \"[0-9]*\.[0-9]*\.[0-9]*\"/s//version = \"${SEMVER}\"/" "$cargo_toml"
        else
            # BSD sed: can't use 0,/pat/ address — use awk for first-occurrence replace
            awk -v ver="$SEMVER" '!done && /^version = "[0-9]+\.[0-9]+\.[0-9]+"/ { sub(/version = "[0-9]+\.[0-9]+\.[0-9]+"/, "version = \""ver"\""); done=1 } 1' "$cargo_toml" > "${cargo_toml}.tmp" && mv "${cargo_toml}.tmp" "$cargo_toml"
        fi
    fi
done

# Update tauri.conf.json
TAURI_CONF="$ROOT/src-tauri/tauri.conf.json"
if [[ -f "$TAURI_CONF" ]]; then
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "s/\"version\": \"[0-9]*\.[0-9]*\.[0-9]*\"/\"version\": \"${SEMVER}\"/" "$TAURI_CONF"
    else
        sed -i '' "s/\"version\": \"[0-9]*\.[0-9]*\.[0-9]*\"/\"version\": \"${SEMVER}\"/" "$TAURI_CONF"
    fi
fi

echo "All version locations updated to $SEMVER (full: $FULL_VERSION)"
echo ""
echo "  VERSION file:    $FULL_VERSION"
echo "  Cargo.toml:      $SEMVER"
echo "  tauri.conf.json: $SEMVER"
