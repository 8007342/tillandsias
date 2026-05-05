#!/usr/bin/env bash
# verify-version-monotonic.sh — Enforce monotonic version increases
# @trace spec:versioning
#
# Purpose: Verify that the current VERSION file is monotonically greater
# than the latest released git tag. This prevents version resets or
# non-monotonic changes that would violate CRDT merge semantics.
#
# Version format: Major.Minor.<ChangeCount|YYMMDD>.Build (stored without 'v' prefix)
# Git tag format: v<Major>.<Minor>.<ChangeCount|YYMMDD>.<Build> (with 'v' prefix)
#
# Supports both old (Major.Minor.ChangeCount.Build) and new (Major.Minor.YYMMDD.Build)
# version schemes. The monotonicity check works the same for both.
#
# Usage:
#   scripts/verify-version-monotonic.sh
#   scripts/verify-version-monotonic.sh --check-tag v0.1.260101.5
#
# Exit codes:
#   0 — current version is monotonically >= latest tag (or no tags exist)
#   1 — current version is < latest tag (monotonicity violated)
#   2 — version parse error or missing VERSION file

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "ERROR: not in a git repository" >&2
    exit 2
}

VERSION_FILE="$REPO_ROOT/VERSION"
[[ -f "$VERSION_FILE" ]] || {
    echo "ERROR: VERSION file not found at $VERSION_FILE" >&2
    exit 2
}

# Parse a version string (format: Major.Minor.<component3>.Build[+hash] or vMajor.Minor.<component3>.Build[+hash])
# Component3 can be either ChangeCount (old) or YYMMDD (new) — both are numeric.
# Optional +hash suffix is stripped before parsing (CalVer with commit provenance).
parse_version() {
    local version="${1#v}"  # Remove 'v' prefix if present
    version="${version%+*}"  # Remove '+hash' suffix if present (CalVer commit provenance)

    # Extract components
    local major="${version%%.*}"
    local rest="${version#*.}"
    local minor="${rest%%.*}"
    rest="${rest#*.}"
    local component3="${rest%%.*}"
    local build="${rest#*.}"

    # Validate format: 4 numeric components separated by dots
    if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && \
            "$component3" =~ ^[0-9]+$ && "$build" =~ ^[0-9]+$ ]]; then
        echo "" >&2
        return 1
    fi

    echo "$major $minor $component3 $build"
}

# Compare two parsed versions (Major Minor Component3 Build format)
# Returns 0 if current >= latest, 1 if current < latest
# Component3 can be ChangeCount (old) or YYMMDD (new) — comparison is numeric either way.
version_compare() {
    local current_major=$1 current_minor=$2 current_component3=$3 current_build=$4
    local latest_major=$5 latest_minor=$6 latest_component3=$7 latest_build=$8

    # Compare Major
    if [[ $current_major -gt $latest_major ]]; then
        return 0  # current > latest
    elif [[ $current_major -lt $latest_major ]]; then
        return 1  # current < latest
    fi

    # Major equal, compare Minor
    if [[ $current_minor -gt $latest_minor ]]; then
        return 0
    elif [[ $current_minor -lt $latest_minor ]]; then
        return 1
    fi

    # Minor equal, compare Component3 (ChangeCount or YYMMDD)
    if [[ $current_component3 -gt $latest_component3 ]]; then
        return 0
    elif [[ $current_component3 -lt $latest_component3 ]]; then
        return 1
    fi

    # Component3 equal, compare Build
    if [[ $current_build -ge $latest_build ]]; then
        return 0
    else
        return 1
    fi
}

# Read current version from VERSION file
current_version="$(cat "$VERSION_FILE" | tr -d ' \n')"
[[ -n "$current_version" ]] || {
    echo "ERROR: VERSION file is empty" >&2
    exit 2
}

# Parse current version
current_parsed=$(parse_version "$current_version") || {
    echo "ERROR: Failed to parse current version '$current_version'" >&2
    exit 2
}
read -r current_major current_minor current_component3 current_build <<< "$current_parsed"

# Optionally override latest tag for testing
check_tag="${1:-}"
if [[ -n "$check_tag" ]]; then
    latest_tag="$check_tag"
else
    # Find latest tag matching v*
    latest_tag="$(git tag -l 'v*' --sort=-version:refname --merged HEAD 2>/dev/null | head -1)" || true
fi

# If no tags exist, current version is automatically monotonic
if [[ -z "$latest_tag" ]]; then
    echo "✓ No prior releases found. Version $current_version is valid for initial release."
    exit 0
fi

# Remove 'v' prefix for parsing
latest_version="${latest_tag#v}"

# Parse latest tag version
latest_parsed=$(parse_version "$latest_tag") || {
    echo "ERROR: Failed to parse latest tag '$latest_tag'" >&2
    exit 2
}
read -r latest_major latest_minor latest_component3 latest_build <<< "$latest_parsed"

# Compare versions
if version_compare "$current_major" "$current_minor" "$current_component3" "$current_build" \
                   "$latest_major" "$latest_minor" "$latest_component3" "$latest_build"; then
    echo "✓ Version $current_version is monotonically >= latest release $latest_tag"
    exit 0
else
    echo "ERROR: Version $current_version is LESS than latest release $latest_tag" >&2
    echo "  Latest:  $latest_version" >&2
    echo "  Current: $current_version" >&2
    echo "" >&2
    echo "Monotonicity violation. Cannot release a version that regresses." >&2
    echo "Update VERSION file to a value >= $latest_version" >&2
    exit 1
fi
