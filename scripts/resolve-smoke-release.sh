#!/usr/bin/env bash
# @trace spec:ci-release
# freshness: auditor=linux-lenovinha-fable5-20260823t215305z date=2026-08-23 verdict=refreshed scope=full file, 68 lines, exercised live against the real repo. BEHAVIOUR CONFIRMED: daily -> `channel:daily tag:v0.4.260817.1 base:.../download/v0.4.260817.1` exit 0; stable -> v0.4.260810.1 exit 0 (correctly a different, older tag — stable trails daily, which is the whole point of the two channels); bogus -> `refused:bad-channel:bogus` exit 1. All three match the falsifiable grammar declared in the header.
# freshness-gap (recorded here rather than as a new ledger row, since this is where the next auditor looks): this resolver has NO executable fixture, unlike its two siblings resolve-open-pr.sh (5/5) and resolve-release-run.sh (6/6). litmus:smoke-release-channel-shape pins it by GREPPING FOR SOURCE STRINGS — `grep -Fq 'CHANNEL="${1:-daily}"'`, `grep -Fq 'grep -E "$TAG_RE" | sort -V | tail -1'` — which constrains the TEXT, not the behaviour. Two consequences, both live today: a correct refactor that changes those strings turns the litmus red, and a behavioural regression that keeps them passes. The sibling fixtures are the model; a test-resolve-smoke-release.sh covering no-release / bad-channel / daily-picks-highest / stable-differs-from-daily would replace a text pin with a real constraint. Not done here: it needs a `gh` stub like the siblings', which is more than a freshness audit's scope.
# resolve-smoke-release.sh — resolve which published release the curl-install
# smoke should exercise, distinguishing the two channels (plan order 305 +
# operator directive 2026-07-15):
#
#   daily  (DEFAULT): the newest release INCLUDING prereleases — i.e. the
#          latest daily. Routine curl-install smoke tracks the bleeding edge,
#          because that is what the next promotion candidate will be.
#   stable: the newest NON-prerelease — what /releases/latest resolves to and
#          what the README install URLs serve. Smoke this ONCE right after a
#          promotion to prove the promoted artifact installs, then go back to
#          `daily` for routine runs.
#
# Output (last line, falsifiable grammar):
#   ^channel:(daily|stable) tag:v[0-9][A-Za-z0-9.\-]* base:https://\S+$
#   ^refused:(no-release|bad-channel):.*$   on failure (exit 1)
#
# The `base` is the release download base the installer should use; feed it to
# install.sh via TILLANDSIAS_RELEASE_BASE so the smoke fetches that exact
# release instead of the hard-coded /releases/latest/download (which is
# stable-only by GitHub semantics).
#
# Usage: scripts/resolve-smoke-release.sh [daily|stable]
set -euo pipefail

REPO="${TILLANDSIAS_REPO:-8007342/tillandsias}"
CHANNEL="${1:-daily}"

# Canonical daily/stable tag grammar (rejects malformed junk like a
# double-'v' historical tag that would otherwise sort first by API order).
TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'

case "$CHANNEL" in
    daily)
        # Newest well-formed release of ANY kind (prereleases included).
        # Filter to the canonical grammar, then pick the highest version —
        # robust to API ordering AND to stray malformed tags in the repo.
        TAG="$(gh api --paginate "repos/${REPO}/releases" --jq '.[].tag_name' 2>/dev/null \
                 | grep -E "$TAG_RE" | sort -V | tail -1 || true)"
        ;;
    stable)
        # Newest non-prerelease (what /releases/latest points at).
        TAG="$(gh api "repos/${REPO}/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
        ;;
    *)
        echo "usage: $0 [daily|stable]" >&2
        echo "refused:bad-channel:${CHANNEL}"
        exit 1
        ;;
esac

# Guard: whatever we resolved must match the canonical grammar.
if [ -n "${TAG:-}" ] && ! printf '%s' "$TAG" | grep -Eq "$TAG_RE"; then
    echo "Resolved ${CHANNEL} tag '${TAG}' is malformed (expected v#.#.#.#); refusing." >&2
    echo "refused:no-release:${CHANNEL}"
    exit 1
fi

if [ -z "${TAG:-}" ] || [ "$TAG" = "null" ]; then
    echo "No ${CHANNEL} release found for ${REPO} (a stable channel needs at least one promoted release)." >&2
    echo "refused:no-release:${CHANNEL}"
    exit 1
fi

# Per-tag download base works for BOTH channels and pins the exact artifact.
BASE="https://github.com/${REPO}/releases/download/${TAG}"
echo "channel:${CHANNEL} tag:${TAG} base:${BASE}"
