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
# prerelease. DEMOTION IS NOT THE INVERSE OF PROMOTION ON THE GITHUB API.
# Do not hand-run the steps: use the subcommand, which performs them in order
# and then VERIFIES by re-reading /releases/latest instead of assuming.
#   scripts/promote-stable.sh demote <mistaken-tag> --to <intended-tag>
# Order 864-mk2p.
#
# Output grammar (last line, falsifiable):
#   ^promoted:v[0-9][A-Za-z0-9.\-]*$              promotion happened
#   ^would-promote:v[0-9][A-Za-z0-9.\-]*$         --dry-run, gates all passed
#   ^demoted:<mistaken>:latest-now:<intended>$    demotion happened AND verified
#   ^would-demote:<mistaken>:latest-would-be:<intended>$   --dry-run
#   ^refused:(no-evidence|no-release|bad-tag|missing-target|demote-verify-failed):.*$
#                                                 refusal (exit 1)
#
# --dry-run RUNS EVERY GATE AND MUTATES NOTHING (order 864-8tqv). It exists
# because the only observable this script offered was its side effect, so the
# natural way to test a change to the evidence gate — run it and read the
# verdict — published a channel change to every user. That happened on
# 2026-08-23: piping this script to `head -4` promoted a release and then
# SIGPIPE-killed it between the `gh release edit` and the stable-tag push,
# leaving the GitHub release and the git tag disagreeing. A command whose effect
# is outward-facing should be ASKABLE.
#
# Usage:
#   scripts/promote-stable.sh vX.Y.YYMMDD.N [--force] [--dry-run]
#   scripts/promote-stable.sh demote <mistaken-tag> --to <intended-tag> [--dry-run]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Flags are order-independent. The old form took --force positionally as $2, so
# `<tag> --force` still parses; `<tag> --dry-run --force` now does too, which the
# positional form silently ignored.
MODE="promote"
TAG=""
TARGET=""
FORCE=""
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        demote)     MODE="demote" ;;
        --force)    FORCE="--force" ;;
        --dry-run)  DRY_RUN=1 ;;
        --to)       shift; TARGET="${1:-}" ;;
        -*)         echo "usage: $0 vX.Y.YYMMDD.N [--force] [--dry-run]" >&2
                    echo "refused:bad-tag:$1"; exit 1 ;;
        *)          if [ -z "$TAG" ]; then TAG="$1"; else TARGET="$1"; fi ;;
    esac
    shift
done

# A tag is well-formed or it is not; both paths need the same answer.
_valid_tag() { printf '%s' "${1:-}" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }

# owner/repo for the endpoints `gh release` does not cover. Derived, never
# hardcoded: this script is read by other forks of the runbook.
_nwo() { gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null; }

if [ -z "$TAG" ] || ! _valid_tag "$TAG"; then
    echo "usage: $0 vX.Y.YYMMDD.N [--force] [--dry-run]" >&2
    echo "refused:bad-tag:${TAG:-<empty>}"
    exit 1
fi

if [ "$MODE" = "demote" ]; then
    # 864-mk2p. Demotion is NOT the inverse of promotion: GitHub's make_latest
    # is sticky, so flipping the mistaken release to prerelease leaves
    # /releases/latest still serving it. The intended release must be named and
    # explicitly re-marked, and then the RESULT must be read back — the whole
    # defect was a remediation step that reported success while the channel
    # stayed wrong.
    if [ -z "$TARGET" ] || ! _valid_tag "$TARGET"; then
        echo "demote needs the release that SHOULD be latest: $0 demote <mistaken> --to <intended>" >&2
        echo "refused:missing-target:${TARGET:-<empty>}"
        exit 1
    fi
    for _t in "$TAG" "$TARGET"; do
        if ! gh release view "$_t" >/dev/null 2>&1; then
            echo "refused:no-release:$_t"
            exit 1
        fi
    done

    NWO="$(_nwo)"
    if [ -z "$NWO" ]; then
        echo "cannot resolve owner/repo; is gh authenticated for this remote?" >&2
        echo "refused:no-release:$TAG"
        exit 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "would demote $TAG, re-mark $TARGET as latest, and move the stable tag." >&2
        echo "would-demote:$TAG:latest-would-be:$TARGET"
        exit 0
    fi

    TARGET_ID="$(gh api "repos/$NWO/releases/tags/$TARGET" --jq .id 2>/dev/null)"
    if [ -z "$TARGET_ID" ]; then
        echo "refused:no-release:$TARGET"
        exit 1
    fi

    gh release edit "$TAG" --prerelease --latest=false
    gh api -X PATCH "repos/$NWO/releases/$TARGET_ID" -f make_latest=true >/dev/null

    TARGET_COMMIT="$(gh release view "$TARGET" --json targetCommitish --jq '.targetCommitish')"
    git -C "$REPO_ROOT" tag -f -a stable -m "Stable channel: demoted $TAG, restored $TARGET" "$TARGET_COMMIT"
    git -C "$REPO_ROOT" push origin refs/tags/stable --force

    # VERIFY, never assume. This read is the entire point of the packet: the
    # documented one-liner reported success with the channel still wrong.
    LATEST_NOW="$(gh api "repos/$NWO/releases/latest" --jq .tag_name 2>/dev/null)"
    if [ "$LATEST_NOW" != "$TARGET" ]; then
        echo "DEMOTION DID NOT TAKE: /releases/latest still resolves to ${LATEST_NOW:-<unknown>}, not $TARGET." >&2
        echo "make_latest is sticky; re-run or PATCH make_latest=true on $TARGET by hand, then re-verify." >&2
        echo "refused:demote-verify-failed:$LATEST_NOW"
        exit 1
    fi
    echo "/releases/latest verified: now resolves to $TARGET." >&2
    echo "demoted:$TAG:latest-now:$TARGET"
    exit 0
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

# 864-8tqv. Every gate above has run; below this line the script mutates an
# outward-facing channel. --dry-run stops exactly here, which is what makes the
# gates testable without publishing anything.
if [ "$DRY_RUN" -eq 1 ]; then
    echo "would promote $TAG: flip prerelease=false + latest, move the stable tag." >&2
    echo "would-promote:$TAG"
    exit 0
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
