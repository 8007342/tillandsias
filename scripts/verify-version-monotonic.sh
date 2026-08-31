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
    # Find the latest release tag REACHABLE FROM HEAD (2026-08-31, the daily-
    # channel deadlock). This used to scan ALL fetched tags, on the premise
    # that every tag is a stable release cut from main. The daily/prerelease
    # channel broke that premise by design: its tags run AHEAD of main as the
    # operator's staging lane, so the moment a host fetched the daily tag,
    # every push was refused as version-not-monotonic while the version guard
    # simultaneously refused the VERSION bump off main — a two-guard deadlock
    # that wedged lenovinha and then macuahuitl within the hour.
    #
    # The property actually worth enforcing: a branch must never regress a
    # tag IT CARRIES. A tag whose commit this branch has never contained is
    # another channel's history, not this branch's past — comparing against
    # it converts "a prerelease exists somewhere" into "nobody can push".
    # The release workflow's own tag-cut check still sees every tag it needs:
    # prior stable tags are ancestors of any branch that merges main, and
    # --check-tag remains available for explicit cross-channel comparisons.
    latest_tag="$(git tag -l 'v*' --merged HEAD --sort=-version:refname 2>/dev/null | head -1)" || true
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
    # ORDER 800-vk2p. The remedy must arrive with the refusal, and it must arrive
    # EARLY. Cutting a release moves the tag within seconds, so every branch still
    # carrying the pre-release VERSION becomes unpushable for something none of
    # them did — at v0.4.260817.1 that was linux-next, windows-next and osx-next
    # simultaneously. The old text was true about a RELEASE while the reader was
    # pushing a plan fragment, and named hand-editing VERSION, which the runbook
    # guardrail and pre-push-version-guard.sh both forbid off main.
    #
    # The REMEDY line is deliberately the second stderr line: the hook that most
    # readers actually meet this through truncates the preflight detail
    # (scripts/hooks/pre-push-local-gate.sh), so a remedy appended at the end is
    # invisible exactly when it is needed.
    branch="$(git symbolic-ref --short HEAD 2>/dev/null)" || branch=""
    echo "ERROR: Version $current_version is LESS than latest release $latest_tag" >&2
    case "$branch" in
        linux-next|main)
            echo "REMEDY: git fetch origin && git merge origin/main" >&2
            echo "A release was just cut: tag $latest_tag moved while this branch still carries $current_version." >&2
            echo "This branch is not broken — it is missing the post-release back-merge (order 800-vk2p; precedent f6424070d)." >&2
            echo "Do NOT edit VERSION by hand off main; the merge is the fix." >&2
            ;;
        windows-next|osx-next)
            echo "REMEDY: git fetch origin && git merge origin/linux-next" >&2
            echo "A release was just cut: tag $latest_tag moved while this branch still carries $current_version." >&2
            echo "linux-next carries main's post-release VERSION, and the pre_push_gate already requires that merge" >&2
            echo "before every non-linux-next push — following the gate in order self-heals this (order 800-vk2p)." >&2
            ;;
        *)
            echo "REMEDY: if a release was just cut, back-merge it: git fetch origin && git merge origin/main (order 800-vk2p)" >&2
            echo "  Latest:  $latest_version" >&2
            echo "  Current: $current_version" >&2
            echo "Monotonicity violation. Cannot release a version that regresses." >&2
            echo "Otherwise update VERSION file to a value >= $latest_version" >&2
            ;;
    esac
    exit 1
fi
