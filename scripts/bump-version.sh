#!/usr/bin/env bash
# =============================================================================
# Tillandsias — Version Bump Script
#
# Reads VERSION file and updates all version locations atomically.
# Version format: Major.Minor.ChangeCount.BuildIncrement
#
# Usage:
#   ./scripts/bump-version.sh              # Sync all files to VERSION
#   ./scripts/bump-version.sh --bump-build # Increment build number
#   ./scripts/bump-version.sh --bump-changes # Increment change count + build (monotonic)
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

# Read current version
FULL_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
IFS='.' read -r MAJOR MINOR CHANGES BUILD <<< "$FULL_VERSION"

# Handle flags
case "${1:-}" in
    --bump-build)
        BUILD=$((BUILD + 1))
        FULL_VERSION="${MAJOR}.${MINOR}.${CHANGES}.${BUILD}"
        echo "$FULL_VERSION" > "$VERSION_FILE"
        echo "Bumped build: $FULL_VERSION"
        ;;
    --bump-changes)
        CHANGES=$((CHANGES + 1))
        BUILD=$((BUILD + 1))
        FULL_VERSION="${MAJOR}.${MINOR}.${CHANGES}.${BUILD}"
        echo "$FULL_VERSION" > "$VERSION_FILE"
        echo "Bumped changes: $FULL_VERSION"
        ;;
    "")
        echo "Syncing version: $FULL_VERSION"
        ;;
    *)
        echo "Usage: $0 [--bump-build|--bump-changes]" >&2
        exit 1
        ;;
esac

# Derive 3-part semver for Cargo/Tauri
SEMVER="${MAJOR}.${MINOR}.${CHANGES}"

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
