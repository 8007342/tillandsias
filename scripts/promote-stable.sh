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
# DEMOTING A MISTAKEN PROMOTION IS NOT ONE COMMAND, and this comment used to
# claim it was (`gh release edit <tag> --prerelease`). Measured false on
# 2026-08-23: that sets prerelease=true and /releases/latest GOES ON SERVING THE
# DEMOTED TAG, because GitHub's `make_latest` is sticky — it is not recomputed
# from "newest non-prerelease by date" just because the current holder became a
# prerelease. The README's /releases/latest/download/... URLs keep pointing at
# the release you just demoted. Full demotion is three steps:
#   gh release edit <tag> --prerelease --latest=false
#   gh api -X PATCH repos/<owner>/<repo>/releases/<id-of-intended> -f make_latest=true
#   git tag -f stable <intended-commit> && git push origin refs/tags/stable --force
# then VERIFY with `gh api repos/<owner>/<repo>/releases/latest --jq .tag_name`
# rather than assuming. Order 864-mk2p turns this into a `demote` subcommand.
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
# Dots are regex wildcards: an unescaped 0.4.260817.1 also matches 0X4X260817X1.
# On a gate that decides releases, accidental permissiveness is the wrong
# direction to be sloppy in.
VERSION_RE="$(printf '%s' "$VERSION_NO_V" | sed 's/\./\\./g')"

# GREP IS LINE-SCOPED, AND THE EVIDENCE IS NOT ALL ON ONE LINE.
#
# The original pattern required "e2e" or "smoke" AND "PASS" AND the version to
# co-occur on a SINGLE line. The e2e skill does not write that line. What it
# writes is plan/issues/smoke-e2e-findings-v<version>-<date>.md containing
#   ## Run 2026-08-17T17:58Z→18:06Z — **PASS** (tag v0.4.260817.1, build …)
# The words "smoke" and "e2e" are in the FILENAME; the PASS and the version are
# on a heading that never repeats them. So a real, dated, unambiguous PASS for
# v0.4.260817.1 existed from 2026-08-17 and this gate reported "No e2e PASS
# evidence" for six days — which is why nothing was promoted, which is why
# hosts then deferred running the e2e ("no release newer than last tested
# evidence"), which is why nothing moved.
#
# The fix keeps the gate falsifiable and does NOT loosen what counts as
# evidence. A file still has to (a) identify itself as e2e/smoke evidence, and
# (b) contain a line asserting PASS for THIS EXACT version. The only change is
# that (a) may be satisfied by the file's name rather than by the same line as
# the verdict.
_has_evidence=0
if grep -rIlE "(e2e|smoke).*(PASS|pass).*${VERSION_RE}|${VERSION_RE}.*(e2e|smoke).*(PASS|pass)" \
        "$REPO_ROOT/plan/" >/dev/null 2>&1; then
    _has_evidence=1
else
    while IFS= read -r _f; do
        [ -n "$_f" ] || continue
        if grep -qE "(PASS|pass).*${VERSION_RE}|${VERSION_RE}.*(PASS|pass)" "$_f" 2>/dev/null; then
            _has_evidence=1
            break
        fi
    done <<EOF
$(find "$REPO_ROOT/plan" -type f -iname "*e2e*${VERSION_NO_V}*" -o -type f -iname "*smoke*${VERSION_NO_V}*" 2>/dev/null)
EOF
fi
if [ "$_has_evidence" -eq 0 ]; then
    if [ "$FORCE" = "--force" ]; then
        echo "WARNING: promoting $TAG WITHOUT e2e PASS evidence in plan/ (--force)." >&2
        echo "Record the override as a cycle entry via 'tillandsias-plan loop-status-append' (who/when/why; never rewrite plan/loop_status.md in place)." >&2
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
