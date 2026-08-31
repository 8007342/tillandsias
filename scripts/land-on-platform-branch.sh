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
#       3 gate failed | 4 attempts exhausted | 5 auth failed
#       6 push failed for a reason retrying cannot fix
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
    # No pipeline: the exit status must be git push's own. KEEP THE OUTPUT — an
    # earlier version discarded it, so a push that failed for a NON-RETRYABLE
    # reason left no diagnostic and this loop retried it to exhaustion, burning a
    # full gate run each time. Measured 2026-08-23: an expired GitHub token cost
    # four gate cycles and reported "origin moved" for all of them.
    _plog="${TMPDIR:-/tmp}/land-push.$$.log"
    git push origin "$BRANCH" > "$_plog" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        # Retrying only helps a LOST RACE. Anything else must refuse at once and
        # carry its remedy: an error read mid-incident should say what to do.
        if grep -qiE "authentication failed|invalid username or token|could not read Username|Permission denied \(publickey\)" "$_plog"; then
            echo "refused:land:auth-failed — git cannot authenticate to origin." >&2
            sed -n '1,3p' "$_plog" >&2
            echo "  The commit is safe locally; nothing was lost. Re-authenticate, then re-run:" >&2
            echo "    gh auth refresh -h github.com && gh auth setup-git" >&2
            echo "    scripts/land-on-platform-branch.sh $BRANCH" >&2
            rm -f "$_plog"; exit 5
        fi
        if ! grep -qiE "non-fast-forward|fetch first|rejected|stale info" "$_plog"; then # sigpipe-ok: safe pipeline
            echo "refused:land:push-failed — not a lost race, so retrying cannot help:" >&2
            sed -n '1,6p' "$_plog" >&2
            rm -f "$_plog"; exit 6
        fi
    fi
    rm -f "$_plog"

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
