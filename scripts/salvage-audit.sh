#!/usr/bin/env bash
# @trace spec:ci-release
#
# salvage-audit.sh — which salvage/work refs on origin hold content that is NOT
# on the target branch, and for each differing file, WHICH SIDE IS AHEAD.
#
# Order 1226-jb8y. RUN THIS. DO NOT RETYPE THE QUERY.
#
# ── WHY THIS IS A SCRIPT ─────────────────────────────────────────────────────
#
# 872-c9nd's salvage net pushes a copy of a dirty worktree to origin, and on
# 2026-09-16 that saved macbookair's finished work when its gate could not pass
# — but the work sat there for hours while two hosts reasoned about escape
# routes, because NOBODY QUERIED THE REFS. The drill's answer was "list the
# salvage refs". The very next pass tried to make that routine and GOT THE
# ANSWER WRONG TWICE, in opposite directions. The question has three parts and
# every single-command shortcut answers a different one:
#
#   ANCESTRY IS NOT INTEGRATION. `git merge-base --is-ancestor` reported nine
#   refs "not contained" — two of which had been relayed by CHERRY-PICK hours
#   earlier, so their content was fully landed and their ancestry never would
#   be. Ancestry answers "was this ref merged", not "is its work present".
#
#   THREE-DOT OVERCOUNTS. `git diff A...B` lists what B changed since the MERGE
#   BASE, which includes files A added independently. Six fragments read as
#   differing; all six were BYTE-IDENTICAL.
#
#   TWO-DOT OVERCOUNTS FAR WORSE. Tip-to-tip counts all of the BRANCH'S progress
#   since the ref branched: 526, 2009 and 2061 files for refs whose real
#   outstanding content was 3, 0 and 0.
#
#   AND "DIFFERS" IS NOT "OUTSTANDING". A file can differ because the BRANCH
#   moved past a stale snapshot. lenovinha's ref differed on two files the
#   branch had touched TWO DAYS LATER, with its row already completed.
#
# So: three-dot for the CANDIDATE set, per-file blob comparison for the REAL
# differing set, and last-touch dates for DIRECTION.
#
# ── VERDICTS (stdout, last line) ─────────────────────────────────────────────
#   ok:salvage-audit:<refs>r:<with>w:<files>f:branch=<b>   audited; <with> refs hold something
#   skipped:salvage-audit:no-refs:<pattern>                nothing matched
#   fail:salvage-audit:unknown-argument:<arg>              nothing was examined
#   fail:salvage-audit:missing-value:<flag>                nothing was examined
#   fail:salvage-audit:bad-branch:<ref>                    nothing was examined
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

BRANCH="origin/linux-next"
PATTERN="refs/heads/salvage/*"
REMOTE="origin"

while [ $# -gt 0 ]; do
    case "$1" in
        --branch)  [ $# -ge 2 ] || { echo "  --branch needs a value; nothing was examined" >&2; echo "fail:salvage-audit:missing-value:--branch"; exit 0; }; BRANCH="$2"; shift 2 ;;
        --pattern) [ $# -ge 2 ] || { echo "  --pattern needs a value; nothing was examined" >&2; echo "fail:salvage-audit:missing-value:--pattern"; exit 0; }; PATTERN="$2"; shift 2 ;;
        --remote)  [ $# -ge 2 ] || { echo "  --remote needs a value; nothing was examined" >&2; echo "fail:salvage-audit:missing-value:--remote"; exit 0; }; REMOTE="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" >&2; exit 0 ;;
        *) echo "  nothing was examined. usage: $(basename "${BASH_SOURCE[0]}") [--branch <ref>] [--pattern <glob>] [--remote <name>]" >&2
           echo "fail:salvage-audit:unknown-argument:$1"; exit 0 ;;
    esac
done

git rev-parse --verify "$BRANCH" >/dev/null 2>&1 || {
    echo "  '$BRANCH' does not resolve; NOTHING was compared. An empty result here would" >&2
    echo "  mean 'could not look', not 'nothing is stranded'." >&2
    echo "fail:salvage-audit:bad-branch:$BRANCH"; exit 0
}

# Fetch the refs into remote-tracking names so blob lookups work offline of the
# remote. A fetch failure is NOT fatal: locally-known refs are still auditable,
# and saying so beats refusing.
git fetch -q "$REMOTE" "+${PATTERN}:refs/remotes/${REMOTE}/${PATTERN#refs/heads/}" 2>/dev/null || \
    echo "  note: could not fetch $PATTERN from $REMOTE; auditing locally-known refs only" >&2

# for-each-ref takes a PREFIX, not a shell glob: a trailing `/*` matches nothing
# here and returns an empty list, which would read as "nothing is stranded" —
# the exact false-negative this script exists to prevent, in its own lookup.
local_pat="refs/remotes/${REMOTE}/${PATTERN#refs/heads/}"
local_pat="${local_pat%/\*}"
refs="$(git for-each-ref --format='%(refname)' "$local_pat" 2>/dev/null)"
if [ -z "$refs" ]; then
    echo "  no refs matched $PATTERN. That is a fact about the PATTERN, not a claim" >&2
    echo "  that nothing is stranded." >&2
    echo "skipped:salvage-audit:no-refs:$PATTERN"; exit 0
fi

nrefs=0; nwith=0; nfiles=0
branch_short="${BRANCH##*/}"
printf 'salvage-audit: branch=%s pattern=%s\n' "$BRANCH" "$PATTERN" >&2
printf '  ANCESTRY IS NOT USED as the integration test: a ref relayed by cherry-pick\n' >&2
printf '  is never an ancestor, yet its work is fully present. Content decides.\n' >&2

while read -r ref; do
    [ -n "$ref" ] || continue
    nrefs=$((nrefs + 1))
    short="${ref#refs/remotes/${REMOTE}/}"
    tip_epoch="$(git log -1 --format=%ct "$ref" 2>/dev/null || echo 0)"
    out=""
    # STEP 1: candidates — what this ref changed since the merge base.
    while read -r f; do
        [ -n "$f" ] || continue
        # STEP 2: is it REALLY different, or did the branch add the same bytes?
        a="$(git rev-parse "$ref:$f" 2>/dev/null || true)"
        b="$(git rev-parse "$BRANCH:$f" 2>/dev/null || true)"
        [ "$a" = "$b" ] && continue
        # STEP 3: direction. A file the BRANCH touched after this snapshot is the
        # branch moving on, not the ref holding something back.
        if [ -z "$b" ]; then
            out="${out}    ${f}  ABSENT-from-${branch_short} (ref holds it)"$'\n'
        else
            bt="$(git log -1 --format=%ct "$BRANCH" -- "$f" 2>/dev/null || echo 0)"
            if [ "${bt:-0}" -gt "${tip_epoch:-0}" ]; then
                out="${out}    ${f}  ${branch_short}-is-AHEAD (stale snapshot)"$'\n'
            else
                out="${out}    ${f}  ref-may-be-AHEAD (predates no branch edit)"$'\n'
            fi
        fi
        nfiles=$((nfiles + 1))
    done < <(git diff --name-only "$BRANCH...$ref" 2>/dev/null)
    if [ -n "$out" ]; then
        nwith=$((nwith + 1))
        printf '  %s\n' "$short" >&2
        printf '%s' "$out" >&2
    fi
done <<EOF
$refs
EOF

if [ "$nwith" -eq 0 ]; then
    printf '  every ref is landed, superseded or stale — nothing outstanding.\n' >&2
else
    printf '  Only `ref-may-be-AHEAD` and `ABSENT` lines are candidates for a relay.\n' >&2
    printf '  A `%s-is-AHEAD` line means the branch moved past a stale snapshot.\n' "$branch_short" >&2
fi
echo "ok:salvage-audit:${nrefs}r:${nwith}w:${nfiles}f:branch=$BRANCH"
