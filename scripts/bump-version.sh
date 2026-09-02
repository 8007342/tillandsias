#!/usr/bin/env bash
# =============================================================================
# Tillandsias — Version Bump Script
#
# Reads VERSION file and updates all version locations atomically.
#
# Version format (operator ruling 2026-08-31, epoch-anchored CalVer):
#     <years_since_epoch>.<month>.<day>.<build>
#     e.g. 2026-08-31 daily build 5  ->  56.8.31.5
#   - years_since_epoch: UTC year - 1970 (Unix-epoch anchor; 56 = 2026)
#   - month, day:        UTC month/day, NO zero padding (v56.8.31, not v56.08.31)
#   - build:             daily build counter, resets to 1 on a new UTC day.
#                        By the Microsoft Store's own field-4-must-be-0 rule,
#                        .0 is reserved for DURABLE builds (the Store/weekly
#                        shape); local daily bumps always produce >=1.
#
# Monotonicity across the 2026-08-31 cutover is structural: every comparator
# (verify-version-monotonic's field-wise compare, git's --sort=version:refname,
# sort -V) resolves at field one, and 56 > 0 beats every legacy v0.x.* tag —
# verified for maxed legacy fields (v0.8.999999.9 < v56.8.31.0). No tag
# rewrite, no flag day.
#
# Overflow horizon: field 1 reaches 65535 (the Store's per-field cap) in the
# year 67505. The MINOR/milestone concept is retired from the version: release
# milestones live in the plan ledger's desired_release ordered buckets and the
# README release row's milestone clause, decoupled from artifact versions.
#
# Cargo semver derivation is the first three fields verbatim:
#     56.8.31  (major=years, minor=month, patch=day)
# which is numerically monotonic per semver's field-wise compare and > every
# legacy 0.x.YYMMDD crate version at the major field.
#
# LEGACY TRANSITION: a VERSION still in the old Major.Minor.YYMMDD.Build shape
# (first field 0) is migrated on the next bump: the date fields are re-derived
# from TODAY (UTC) in the new encoding and the build counter starts at 1.
#
# Usage:
#   ./scripts/bump-version.sh              # Sync all files to VERSION
#   ./scripts/bump-version.sh --bump-build # Increment daily build counter
#   ./scripts/bump-version.sh --new-day    # New UTC day, reset build to 1
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

FULL_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
IFS='.' read -r YEARS MONTH DAY BUILD <<< "$FULL_VERSION"

# Today's date in the new encoding.
# MUST be UTC: release tags (merge-to-main-and-release) and all multi-host
# coordination timestamps are UTC. Using local time here regressed VERSION on
# hosts west of UTC — e.g. a PDT build late on UTC-day N saw the UTC-dated
# VERSION as "ahead of today", reset the build counter to a prior day, and then
# failed verify-version-monotonic against the already-published UTC tag.
TODAY_YEARS="$(( $(date -u +%Y) - 1970 ))"
TODAY_MONTH="$(date -u +%-m)"
TODAY_DAY="$(date -u +%-d)"

# Hard walls, asserted rather than discovered (carried from the encoder this
# scheme replaced): field 1 must stay under the Store's 65535 per-field cap
# (year 67505 — recorded, not worried about), and must never be 0 — a leading
# zero is the exact Store rejection the scheme exists to end. A legacy
# 0.x.YYMMDD.N VERSION is the sanctioned exception: it migrates below.
if (( TODAY_YEARS <= 0 || TODAY_YEARS > 65535 )); then
    echo "ERROR: years-since-epoch field ${TODAY_YEARS} is outside (0, 65535] — clock broken or the year is 67506" >&2
    exit 1
fi

legacy=0
if [[ "$YEARS" == "0" ]]; then
    legacy=1
fi

same_day() {
    [[ "$YEARS" == "$TODAY_YEARS" && "$MONTH" == "$TODAY_MONTH" && "$DAY" == "$TODAY_DAY" ]]
}

case "${1:-}" in
    --bump-build)
        if (( legacy )); then
            echo "NOTICE: migrating legacy version $FULL_VERSION to the epoch-anchored scheme (operator ruling 2026-08-31)"
            YEARS="$TODAY_YEARS"; MONTH="$TODAY_MONTH"; DAY="$TODAY_DAY"
            BUILD=1
        elif ! same_day; then
            echo "NOTICE: Date has changed (${YEARS}.${MONTH}.${DAY} → ${TODAY_YEARS}.${TODAY_MONTH}.${TODAY_DAY}), resetting build to 1"
            YEARS="$TODAY_YEARS"; MONTH="$TODAY_MONTH"; DAY="$TODAY_DAY"
            BUILD=1
        else
            BUILD=$((BUILD + 1))
        fi
        FULL_VERSION="${YEARS}.${MONTH}.${DAY}.${BUILD}"
        echo "Bumping build: $FULL_VERSION"
        ;;
    --new-day)
        YEARS="$TODAY_YEARS"; MONTH="$TODAY_MONTH"; DAY="$TODAY_DAY"
        BUILD=1
        FULL_VERSION="${YEARS}.${MONTH}.${DAY}.${BUILD}"
        echo "New day: $FULL_VERSION"
        ;;
    --bump-minor)
        echo "ERROR: --bump-minor is retired — the version carries no milestone field." >&2
        echo "Milestones live in the plan ledger (desired_release ordered buckets) and" >&2
        echo "the README release row's milestone clause (operator ruling 2026-08-31)." >&2
        exit 1
        ;;
    "")
        if (( legacy )); then
            echo "WARNING: VERSION $FULL_VERSION is legacy-shaped; run --bump-build to migrate" >&2
        elif ! same_day; then
            echo "WARNING: Version date (${YEARS}.${MONTH}.${DAY}) is behind today (${TODAY_YEARS}.${TODAY_MONTH}.${TODAY_DAY})"
            echo "         (a sync never advances the date; use --bump-build or --new-day)"
        fi
        echo "Syncing version: $FULL_VERSION"
        ;;
    *)
        echo "Usage: $0 [--bump-build|--new-day]" >&2
        exit 1
        ;;
esac

# Write VERSION
printf '%s\n' "$FULL_VERSION" > "$VERSION_FILE"

# Derive 3-part semver for Cargo package versions: the first three fields
# verbatim (years.month.day) — numerically monotonic, and > every legacy
# 0.x.* crate version at the major field.
IFS='.' read -r V1 V2 V3 _ <<< "$FULL_VERSION"
SEMVER="${V1}.${V2}.${V3}"

# Update all Cargo.toml files (workspace members)
for cargo_toml in \
    "$ROOT/crates/tillandsias-core/Cargo.toml" \
    "$ROOT/crates/tillandsias-scanner/Cargo.toml" \
    "$ROOT/crates/tillandsias-podman/Cargo.toml" \
    "$ROOT/crates/tillandsias-headless/Cargo.toml"; do
    if [[ -f "$cargo_toml" ]]; then
        # 765-uti9 quick win (audit F6.4): same-day bumps leave SEMVER unchanged,
        # and an unconditional rewrite still touches the mtime — which feeds the
        # find -newer staleness probes and forces needless sidecar/workspace
        # rebuilds. Skip byte-identical rewrites; a real SEMVER change fails
        # this grep and rewrites exactly as before.
        if grep -q "^version = \"${SEMVER}\"" "$cargo_toml"; then
            continue
        fi
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

echo "All version locations updated to $SEMVER (full: $FULL_VERSION)"
echo ""
echo "  VERSION file:    $FULL_VERSION"
echo "  Cargo.toml:      $SEMVER"
