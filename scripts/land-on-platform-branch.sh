#!/usr/bin/env bash
# @trace order:859-4jny, spec:ci-release
#
# land-on-platform-branch.sh — rebase, gate, push, and PROVE the commit landed.
#
# WHY THIS EXISTS. On a slow host ./build.sh --check takes minutes, a rebase
# invalidates the gate stamp, and origin moves inside that window — so the
# pre-push hook refuses with "The gate validated a different tree than the one
# you are pushing" and the whole cycle must repeat. Measured on pirria (4 Alder
# Lake-N cores, order 855-wrr3): origin/linux-next moved TWICE between gate
# start and push in one session, and a later commit needed three attempts.
# Retrying is REQUIRED to land at all, so every slow host writes this loop.
#
# THE TWO BUGS THAT LOOP ACQUIRES, both hit for real before this file existed:
#
#   1. `if git push ... | tee LOG | tail -3; then` tests the exit status of
#      TAIL, not of git push. A pipeline's status is its LAST command, so a
#      rejected push reads as success.
#   2. Grepping the output for "<branch> -> <branch>" ALSO matches the
#      rejection line: `! [rejected]  linux-next -> linux-next (fetch first)`.
#
# Together they reported "LANDED" for a push that was refused, and the agent
# reported that onward. NEITHER a zero exit status NOR a ref-update line in the
# output is sufficient evidence that a commit landed; this script asks the
# REMOTE, with `git merge-base --is-ancestor` against a freshly fetched ref.
#
# Usage:
#   scripts/land-on-platform-branch.sh [branch] [max-attempts]
#   scripts/land-on-platform-branch.sh linux-next 4
#
# Exit: 0 landed (verified against origin) | 1 dirty tree | 2 rebase conflict
#       3 gate failed | 4 attempts exhausted
set -uo pipefail

BRANCH="${1:-$(git rev-parse --abbrev-ref HEAD)}"
ATTEMPTS="${2:-4}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "refused:land:dirty-worktree — commit or stash first" >&2
    exit 1
fi

for attempt in $(seq 1 "$ATTEMPTS"); do
    echo "land: attempt $attempt/$ATTEMPTS — fetch + rebase onto origin/$BRANCH"
    git fetch -q origin "$BRANCH" || { echo "land:fetch-failed" >&2; exit 4; }
    if ! git rebase "origin/$BRANCH" >/dev/null 2>&1; then
        git rebase --abort >/dev/null 2>&1
        echo "refused:land:rebase-conflict — resolve by hand" >&2
        exit 2
    fi

    echo "land: attempt $attempt — gate (./build.sh --check)"
    if ! ./build.sh --check >/dev/null 2>&1; then
        echo "refused:land:gate-failed — run ./build.sh --check to see why" >&2
        exit 3
    fi

    echo "land: attempt $attempt — push"
    # No pipeline: the exit status must be git push's own.
    git push origin "$BRANCH" >/dev/null 2>&1
    rc=$?

    # The only proof that counts: ask the remote.
    git fetch -q origin "$BRANCH" 2>/dev/null
    if git merge-base --is-ancestor HEAD "origin/$BRANCH" 2>/dev/null; then
        echo "ok:land:$(git rev-parse --short HEAD):attempt-$attempt"
        exit 0
    fi
    echo "land: push did not land (rc=$rc); origin moved — retrying"
done

echo "refused:land:attempts-exhausted:$ATTEMPTS — origin is moving faster than this host gates" >&2
exit 4
