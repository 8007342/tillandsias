#!/usr/bin/env bash
# @trace spec:observatorium-dashboard, spec:ci-release
# advance-deploy-ref.sh — move a deploy branch so its tip carries a release's
# exact tree. Order 1798-khw6.
#
# WHY A BRANCH. Cloudflare Workers Builds triggers on branch pushes only; it
# cannot watch the `stable` TAG. The observatorium Worker's only trigger is
# its production branch, refs/heads/deploy/observatorium, and nothing but
# scripts/promote-stable.sh moves it. So a stable promotion (or demotion) is
# the ONLY event that builds and deploys the dashboard; every other push in
# this repository starts nothing.
#
# WHY NOT A FORCE-PUSH. The enclave git mirror rejects any refs/heads/* update
# whose old tip is not an ancestor of the new one ("Branch rewind is rejected
# before relay", spec:git-mirror-service). A promotion is normally a
# descendant of the last one and fast-forwards. A demotion, or a promotion of
# an older release, would be a rewind, so instead this writes a RESTORE commit
# on top: tree = the release commit's tree, first parent = the release commit
# (on main), second parent = the deploy ref's current tip. The ref only moves
# forward and the deployed bytes equal the release's. pre-push-local-gate.sh
# exempts exactly these two shapes (1798-khw6).
#
# Usage:
#   scripts/advance-deploy-ref.sh <commit-ish> [--label <tag>] [--remote <r>]
#                                 [--ref refs/heads/deploy/<name>] [--dry-run]
#
# Output grammar (last line, falsifiable):
#   ^verified:deploy-ref:<remote-sha>:tree=<tree>$   origin's ref carries the tree
#   ^would-advance:deploy-ref:<ref>:<commit>$        --dry-run
#   ^refused:deploy-ref-(bad-ref|unresolvable|push-refused|unverified|not-moved):.*$
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_afford() { printf '  why: %s\n  remedy: %s\n' "$1" "$2" >&2; }
REMOTE="origin"
REF="refs/heads/deploy/observatorium"
LABEL=""
TARGET=""
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --label)   shift; LABEL="${1:-}" ;;
        --remote)  shift; REMOTE="${1:-}" ;;
        --ref)     shift; REF="${1:-}" ;;
        --dry-run) DRY_RUN=1 ;;
        -*)        _afford "flags are --label, --remote, --ref and --dry-run" "drop or correct $1"
                   echo "refused:deploy-ref-bad-ref:unknown-flag:$1"; exit 1 ;;
        *)         TARGET="$1" ;;
    esac
    shift
done

case "$REF" in
    refs/heads/deploy/?*) ;;
    *) _afford "only refs/heads/deploy/* is a deploy ref; the pre-push exemption covers nothing else" \
               "pass --ref refs/heads/deploy/<name>, or omit --ref for refs/heads/deploy/observatorium"
       echo "refused:deploy-ref-bad-ref:${REF:-<empty>}"; exit 1 ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then
    echo "would advance $REF on $REMOTE to the tree of ${TARGET:-<empty>} (fast-forward, or a restore commit when that would rewind)." >&2
    echo "would-advance:deploy-ref:$REF:${TARGET:-<empty>}"
    exit 0
fi

g() { git -C "$REPO_ROOT" "$@"; }

COMMIT="$(g rev-parse --verify --quiet "${TARGET:-}^{commit}" || true)"
if [ -z "$COMMIT" ]; then
    _afford "'${TARGET:-<empty>}' names no commit in this checkout" \
            "pass a release tag or sha; fetch it first: git fetch origin refs/tags/<tag>:refs/tags/<tag>"
    echo "refused:deploy-ref-unresolvable:${TARGET:-<empty>}"; exit 1
fi
TREE="$(g rev-parse "$COMMIT^{tree}")"

# Ask origin for the ref's CURRENT tip, then make sure the object is local.
# An absent ref is the first seeding: push the release commit itself.
OLD="$(g ls-remote "$REMOTE" "$REF" 2>/dev/null | awk '{print $1}' | head -1)"
if [ -n "$OLD" ] && ! g cat-file -e "$OLD^{commit}" 2>/dev/null; then
    g fetch -q "$REMOTE" "$REF" 2>/dev/null || true
fi
if [ -n "$OLD" ] && ! g cat-file -e "$OLD^{commit}" 2>/dev/null; then
    _afford "origin's $REF tip $OLD could not be fetched, so a fast-forward cannot be built on it" \
            "check that $REMOTE is reachable (git fetch $REMOTE $REF), then re-run"
    echo "refused:deploy-ref-unresolvable:$OLD"; exit 1
fi

NEW=""
if [ -z "$OLD" ] || g merge-base --is-ancestor "$OLD" "$COMMIT"; then
    NEW="$COMMIT"
elif [ "$(g rev-parse "$OLD^{tree}")" = "$TREE" ]; then
    # Already deploying these bytes (a re-promotion): nothing to push, and
    # pushing would start a build of identical content.
    NEW=""
    echo "$REF already carries the tree of $COMMIT; nothing to push." >&2
else
    NEW="$(g commit-tree "$TREE" -p "$COMMIT" -p "$OLD" \
        -m "deploy: restore ${LABEL:-$COMMIT} on ${REF#refs/heads/}" \
        -m "Tree is exactly ${COMMIT}'s. Written by scripts/advance-deploy-ref.sh so the branch moves forward instead of rewinding (1798-khw6).")"
fi

if [ -n "$NEW" ] && [ "$NEW" != "$OLD" ]; then
    _rc=0
    g push "$REMOTE" "$NEW:$REF" || _rc=$?
    if [ "$_rc" -ne 0 ]; then
        _afford "the push of $NEW to $REMOTE $REF failed (rc=$_rc): the hook lines above name the guard, or $REMOTE was unreachable" \
                "clear what the hook names, then re-run scripts/advance-deploy-ref.sh $COMMIT${LABEL:+ --label $LABEL}"
        echo "refused:deploy-ref-push-refused:$NEW"; exit 1
    fi
fi

# VERIFY ON ORIGIN by tree, not by sha: a restore commit's sha is new, and the
# claim this script makes is about the bytes Cloudflare will build.
REMOTE_TIP="$(g ls-remote "$REMOTE" "$REF" 2>/dev/null | awk '{print $1}' | head -1)"
if [ -z "$REMOTE_TIP" ]; then
    _afford "pushed, but $REMOTE could not be read back; this is not a report that the ref is wrong" \
            "verify by hand: git ls-remote $REMOTE $REF (expect a commit whose tree is $TREE)"
    echo "refused:deploy-ref-unverified:${NEW:-$OLD}"; exit 1
fi
g cat-file -e "$REMOTE_TIP^{commit}" 2>/dev/null || g fetch -q "$REMOTE" "$REF" 2>/dev/null || true
REMOTE_TREE="$(g rev-parse --verify --quiet "$REMOTE_TIP^{tree}" || true)"
if [ "$REMOTE_TREE" != "$TREE" ]; then
    _afford "$REMOTE $REF is at $REMOTE_TIP, whose tree is not ${COMMIT}'s, so Cloudflare would build other bytes" \
            "fetch, then re-run scripts/advance-deploy-ref.sh $COMMIT${LABEL:+ --label $LABEL}"
    echo "refused:deploy-ref-not-moved:$REMOTE_TIP:expected-tree:$TREE"; exit 1
fi
echo "verified:deploy-ref:$REMOTE_TIP:tree=$TREE"
