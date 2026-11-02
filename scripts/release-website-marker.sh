#!/usr/bin/env bash
# @trace order:1846-dykd
#
# release-website-marker.sh <previous-stable-commit> <release-commit>
#
# Prints, one per line, the reason of every `Website-Update: <reason>` commit
# trailer in <previous-stable>..<release>, oldest first, de-duplicated. Prints
# nothing when no commit in the range carries one. Exit 0 either way; exit 2
# when a commit cannot be resolved.
#
# Operator request 2026-10-24: some releases need a website update (the first
# is the release that retires local host-checkout launches, a main feature on
# tillandsias.org). The trailer travels with the change that causes it, so the
# author states it once, and the marker is recomputable from git at any time.
# With no previous stable (the first promotion) the range is the release's
# whole history.
set -euo pipefail
prev="${1:-}"
release="${2:-}"
[ -n "$release" ] || { echo "usage: $0 <previous-stable-commit|''> <release-commit>" >&2; exit 2; }
_afford() { printf '  why: %s\n  remedy: %s\n' "$1" "$2" >&2; }
if ! git rev-parse --verify -q "${release}^{commit}" >/dev/null; then
    echo "refused:website-marker:unresolvable:$release" >&2
    _afford "the release commit is not in this repository, so its range cannot be read" "fetch the release tag (git fetch origin tag <tag>) and run again"
    exit 2
fi
range="$release"
if [ -n "$prev" ]; then
    if ! git rev-parse --verify -q "${prev}^{commit}" >/dev/null; then
        echo "refused:website-marker:unresolvable:$prev" >&2
        _afford "the previous stable commit is not in this repository" "fetch the stable tag (git fetch origin tag stable) or pass '' for a first promotion"
        exit 2
    fi
    range="$prev..$release"
fi
git log --reverse --format='%(trailers:key=Website-Update,valueonly)' "$range" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | awk 'length($0) > 0 && !seen[$0]++'
