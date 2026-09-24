#!/usr/bin/env bash
# allocate-gate-step-prefix.sh — move a NEW gate step whose numeric prefix is
# already taken to a free slot, AFTER the integrate and BEFORE the gate
# (order 1162-qbrx). Called by scripts/land-on-platform-branch.sh in the only
# window that cannot race; runnable by hand for a hand-rolled push.
#
# WHY. scripts/gate-steps.d/NNN-<order>.step files are ordered by a scarce
# integer prefix chosen at authoring time, and the gate's own fixture
# (test-gate-step-append-no-conflict.sh, arm 7) refuses a tree where two
# files share one — the spacing exists so a later step can land between
# two without renaming either, and a doubly-occupied slot loses that gap.
# The skill's advice was "pick the prefix after the integrate"; MEASURED
# 2026-09-13 (lenovinha): 215, 255 and 280 collided against yoga's 900-z3kv
# landing mid-gate, and the 280 case followed the advice exactly. The window
# is not merge-to-commit, it is the gate itself (8–40 minutes), so no
# authoring-time choice closes it. Each collision cost a full re-gate.
#
# WHAT IT DOES. The ADDED set is every .step file in HEAD that is absent
# from --base (the remote tip the land just integrated) and from every
# --exclude ref (the other refs the integrate merged: on a platform branch
# the land tool merges origin/linux-next too, and trunk's own steps must
# never be renamed — they are published). For each added file, in name
# order: if another file in HEAD's tree carries the same prefix STRING, the
# added file moves to a free slot BETWEEN its prefix and the next occupied
# prefix above it, midpoint first (so the gap survives another collision),
# then the nearest free integer in that interval; with --commit the renames
# are committed. Two added files sharing a prefix with each other: the first
# keeps it, the second moves. The bound is taken from the occupancy at ENTRY
# so a sibling moved by this same run does not shrink the interval; freeness
# is tested against the LIVE occupancy so two siblings never land on one
# slot. No free integer in the interval: refuse, undo any rename this run
# made, exit 1 — renumber by hand, above the next occupied prefix if the
# step's place allows. Existing steps are never renumbered (NOT IN SCOPE).
#
# VERDICTS (stdout, last line):
#   ok:gate-step-prefix:no-collision              nothing to do
#   ok:gate-step-prefix:reallocated:<n>           n file(s) renamed (and committed with --commit)
#   ok:gate-step-prefix:dry-run:<n>               --dry-run: the SAME plan --commit would apply; nothing moved
#   refused:gate-step-prefix:no-gap:<file>        no free integer before the next occupied prefix
#   refused:gate-step-prefix:overflow:<file>      the slot would not fit the prefix width (999 -> 1000
#                                                 sorts FIRST under the runner's glob; refused, not widened)
#   refused:gate-step-prefix:usage:<detail>       a flag this script does not take, --base missing, or
#                                                 --base/--exclude not an ancestor of HEAD (integrate first)
# Each rename is also printed as `gate-step-prefix: <old> -> <new> (NNN taken by <other>)`.
# On every refused: verdict the tree is exactly as it was.
#
# Usage: scripts/allocate-gate-step-prefix.sh --base <ref> [--exclude <ref>]... [--commit | --dry-run]
set -euo pipefail

BASE=""; MODE="stage"; EXCLUDES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE="${2:-}"; shift 2 ;;
        --exclude) EXCLUDES="$EXCLUDES ${2:-}"; shift 2 ;;
        --commit) MODE="commit"; shift ;;
        --dry-run) MODE="dry"; shift ;;
        -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 0 ;;
        *) echo "refused:gate-step-prefix:usage:$1"; exit 2 ;;
    esac
done
[ -n "$BASE" ] || { echo "refused:gate-step-prefix:usage:--base <ref> is required"; exit 2; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "refused:gate-step-prefix:not-a-git-checkout"; exit 2; }
cd "$ROOT"
DIR="scripts/gate-steps.d"
for r in $BASE $EXCLUDES; do
    git rev-parse --verify --quiet "$r^{commit}" >/dev/null || { echo "refused:gate-step-prefix:usage:$r does not resolve"; exit 2; }
    if ! git merge-base --is-ancestor "$r" HEAD 2>/dev/null; then
        echo "gate-step-prefix: $r is not an ancestor of HEAD — the integrate has not happened, so HEAD cannot see the remote's steps; integrate first" >&2
        echo "refused:gate-step-prefix:usage:$r is not an ancestor of HEAD (integrate first)"; exit 2
    fi
done

if [ -n "${CARGO_TARGET_DIR:-}" ]; then
    case "$CARGO_TARGET_DIR" in
        /* | [A-Za-z]:[/\\]*) _tmpbase="${CARGO_TARGET_DIR%/}/plan-scratch" ;;
        *) _tmpbase="$ROOT/${CARGO_TARGET_DIR%/}/plan-scratch" ;;
    esac
else
    _tmpbase="${TMPDIR:-/tmp}/plan-scratch"
fi
mkdir -p "$_tmpbase" 2>/dev/null || _tmpbase="${TMPDIR:-/tmp}"
tmp="$(mktemp -d "$_tmpbase/gate-step-prefix.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM

# The prefix is the leading digit run of the basename (the string, zero
# padding included); a file without one is not ordered by this scheme.
_prefix() { # basename -> digits or ""
    local p="${1%%-*}"
    case "$p" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$p" ;; esac
}

# Occupancy at ENTRY: "<prefix>\t<basename>" for every ordered .step in HEAD.
: > "$tmp/entry"
git ls-tree --name-only HEAD "$DIR/" 2>/dev/null > "$tmp/tree" || true
while IFS= read -r f; do
    case "$f" in *.step) ;; *) continue ;; esac
    b="${f##*/}"; p="$(_prefix "$b")"
    [ -n "$p" ] || continue
    printf '%s\t%s\n' "$p" "$b" >> "$tmp/entry"
done < "$tmp/tree"
sort "$tmp/entry" > "$tmp/live"

# Files ADDED by this push: in HEAD, absent from --base and from every --exclude.
git diff --name-only --diff-filter=A "$BASE" HEAD -- "$DIR/" 2>/dev/null | grep '\.step$' | sort > "$tmp/added0" || true
: > "$tmp/added"
while IFS= read -r f; do
    [ -n "$f" ] || continue
    keep=1
    for x in $EXCLUDES; do
        if git cat-file -e "$x:$f" 2>/dev/null; then keep=0; break; fi
    done
    [ "$keep" -eq 1 ] && printf '%s\n' "$f" >> "$tmp/added"
done < "$tmp/added0"

: > "$tmp/renames"
_undo() { # reverse every rename this run performed (non-dry modes)
    [ "$MODE" = "dry" ] && return 0
    [ -s "$tmp/renames" ] || return 0
    tail -r "$tmp/renames" 2>/dev/null > "$tmp/rev" || tac "$tmp/renames" > "$tmp/rev" 2>/dev/null || sort -r "$tmp/renames" > "$tmp/rev"
    while IFS=$'\t' read -r old new; do git mv -- "$new" "$old" 2>/dev/null || true; done < "$tmp/rev"
}
_occupied_live() { awk -F'\t' -v c="$1" '($1+0)==c {found=1} END {exit !found}' "$tmp/live"; }

renamed=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    b="${f##*/}"; p="$(_prefix "$b")"
    [ -n "$p" ] || continue
    n=$((10#$p)); width="${#p}"
    # A collider is another file with the same prefix STRING (arm 7's own
    # definition). One that is ITSELF added by this push and sorts after me
    # is not my problem — it moves on its own turn; the first keeps the slot.
    awk -F'\t' -v p="$p" -v me="$b" '$1==p && $2!=me {print $2}' "$tmp/live" > "$tmp/colliders"
    other=""
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        if grep -qxF "$DIR/$c" "$tmp/added" && [ "$c" \> "$b" ]; then continue; fi
        other="$c"; break
    done < "$tmp/colliders"
    [ -n "$other" ] || continue
    # The interval is (n, next) with next the smallest ENTRY prefix above n.
    next="$(awk -F'\t' -v n="$n" '($1+0)>n {print $1+0}' "$tmp/entry" | sort -n | head -1)"
    limit=1; i=0; while [ "$i" -lt "$width" ]; do limit=$((limit*10)); i=$((i+1)); done
    new=""
    if [ -n "$next" ]; then
        gap=$((next-n))
        if [ "$gap" -gt 1 ]; then
            mid=$((n + gap/2))
            cand="$mid"
            while [ "$cand" -lt "$next" ]; do _occupied_live "$cand" || { new="$cand"; break; }; cand=$((cand+1)); done
            if [ -z "$new" ]; then
                cand=$((mid-1))
                while [ "$cand" -gt "$n" ]; do _occupied_live "$cand" || { new="$cand"; break; }; cand=$((cand-1)); done
            fi
        fi
        if [ -z "$new" ]; then
            _undo
            echo "gate-step-prefix: $b shares prefix $p with $other and no integer between $n and the next occupied prefix $next is free — renumber by hand (above $next if the step's place allows)" >&2
            echo "refused:gate-step-prefix:no-gap:$f"; exit 1
        fi
    else
        cand=$((n+10))
        while [ "$cand" -lt "$limit" ]; do _occupied_live "$cand" || { new="$cand"; break; }; cand=$((cand+1)); done
    fi
    if [ -z "$new" ] || [ "$new" -ge "$limit" ]; then
        _undo
        echo "gate-step-prefix: $b shares prefix $p with $other and the next free slot would not fit $width digits (a wider prefix sorts FIRST under the runner's glob) — renumber by hand" >&2
        echo "refused:gate-step-prefix:overflow:$f"; exit 1
    fi
    newp="$(printf "%0${width}d" "$new")"
    newb="${newp}-${b#*-}"
    echo "gate-step-prefix: $b -> $newb ($p taken by $other)"
    if [ "$MODE" != "dry" ]; then
        git mv -- "$f" "$DIR/$newb"
    fi
    # The live occupancy follows the plan in EVERY mode, so --dry-run previews
    # exactly what --commit performs.
    awk -F'\t' -v me="$b" '$2!=me' "$tmp/live" > "$tmp/live2"
    printf '%s\t%s\n' "$newp" "$newb" >> "$tmp/live2"
    sort "$tmp/live2" > "$tmp/live"
    printf '%s\t%s\n' "$f" "$DIR/$newb" >> "$tmp/renames"
    renamed=$((renamed+1))
done < "$tmp/added"

if [ "$renamed" -eq 0 ]; then
    echo "ok:gate-step-prefix:no-collision"; exit 0
fi
if [ "$MODE" = "dry" ]; then
    echo "ok:gate-step-prefix:dry-run:$renamed"; exit 0
fi
if [ "$MODE" = "commit" ]; then
    if ! git var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
        export GIT_AUTHOR_NAME="tillandsias" GIT_AUTHOR_EMAIL="land@localhost" \
               GIT_COMMITTER_NAME="tillandsias" GIT_COMMITTER_EMAIL="land@localhost"
    fi
    msg="land: gate-step prefix reallocated after the integrate (1162-qbrx)

The integrate brought in a step with the same numeric prefix as one this push
adds; the added step moved to a free slot between its prefix and the next
occupied one so it keeps the place its author chose. Existing steps untouched.

$(awk -F'\t' '{print "  " $1 " -> " $2}' "$tmp/renames")"
    git commit -q -m "$msg"
fi
echo "ok:gate-step-prefix:reallocated:$renamed"
