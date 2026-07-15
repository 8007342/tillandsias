#!/usr/bin/env bash
# @trace spec:ci-release
# promote-stable.sh — promote a vetted daily release to the STABLE channel.
# Plan order 305 (stable-release-channel).
#
# Dailies are published as PRE-releases (release.yml), so the README's
# /releases/latest/download/... install URLs resolve to the newest
# NON-prerelease — i.e. whatever this script last promoted. Promotion:
#   1. requires curl-install e2e PASS evidence for the tag in plan/
#      (the operator-owned gate; --force overrides with a loud record),
#   2. flips the release to prerelease=false and marks it "latest",
#   3. moves the annotated `stable` git tag to the release commit.
# Demote a mistaken promotion with: gh release edit <tag> --prerelease
#
# Output grammar (last line, falsifiable):
#   ^promoted:v[0-9][A-Za-z0-9.\-]*$      on success
#   ^refused:(no-evidence|no-release|bad-tag):.*$  on refusal (exit 1)
#
# Usage: scripts/promote-stable.sh vX.Y.YYMMDD.N [--force]

set -euo pipefail

TAG="${1:-}"
FORCE="${2:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "$TAG" ] || ! printf '%s' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "usage: $0 vX.Y.YYMMDD.N [--force]" >&2
    echo "refused:bad-tag:${TAG:-<empty>}"
    exit 1
fi

if ! gh release view "$TAG" >/dev/null 2>&1; then
    echo "refused:no-release:$TAG"
    exit 1
fi

# Evidence gate: a dated plan record of a curl-install (or local-build) e2e
# PASS naming this exact tag/version. Promotion is an explicit operator
# (Tlatoani) action; the gate makes "vetted" falsifiable rather than vibes.
VERSION_NO_V="${TAG#v}"
if ! grep -rIlE "(e2e|smoke).*(PASS|pass).*${VERSION_NO_V}|${VERSION_NO_V}.*(e2e|smoke).*(PASS|pass)" \
        "$REPO_ROOT/plan/" >/dev/null 2>&1; then
    if [ "$FORCE" = "--force" ]; then
        echo "WARNING: promoting $TAG WITHOUT e2e PASS evidence in plan/ (--force)." >&2
        echo "Record the override in plan/loop_status.md (who/when/why)." >&2
    else
        echo "No e2e PASS evidence for $VERSION_NO_V found under plan/." >&2
        echo "Run /smoke-curl-install-and-test-e2e first, or pass --force (operator override)." >&2
        echo "refused:no-evidence:$TAG"
        exit 1
    fi
fi

gh release edit "$TAG" --prerelease=false --latest

# Move the annotated stable tag to the release's commit.
COMMIT="$(gh release view "$TAG" --json targetCommitish --jq '.targetCommitish')"
git -C "$REPO_ROOT" tag -f -a stable -m "Stable channel: promoted $TAG" "$COMMIT"
git -C "$REPO_ROOT" push origin refs/tags/stable --force

echo "Stable channel now serves $TAG (README /releases/latest URLs resolve to it)." >&2
echo "NEXT: run a ONE-SHOT stable curl-install smoke to prove the promoted" >&2
echo "artifact installs — SMOKE_CHANNEL=stable /smoke-curl-install-and-test-e2e —" >&2
echo "then routine smoke goes back to the daily channel (default)." >&2
echo "promoted:$TAG"
