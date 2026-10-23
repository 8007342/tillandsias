#!/usr/bin/env bash
# verify-set.sh — order 1835-v7vx.
# @trace order:1835-v7vx, order:1831-74sf
#
# WHY: the replay set is only an acceptance instrument if each row can tell a
# fixed tree from an unfixed one. A closure command that is green on the
# pre-fix tree accepts ANY patch (including none); one that is red on the
# landed tree rejects the real fix. This guard proves both ends per row:
#
#   pre-fix tree  = `git archive <prefix_sha>` + the overlay files taken from
#                   <landed_sha> (the test the fix shipped with — without it a
#                   fix that changed its own fixture would look green pre-fix)
#                   -> closure command must FAIL
#   landed tree   = `git archive <landed_sha>`
#                   -> closure command must PASS
#   and <landed_sha> must be an ancestor of origin/linux-next.
#
# Data: replay-set.tsv beside this script, tab separated:
#   order  landed_sha  prefix_sha  overlay_files(space-sep)  owned_files(comma-sep)  closure_command
# Lines starting with '#' are comments.
#
# Usage: verify-set.sh [--list] [<order> ...]      (no order = every row)
#
#   ok:replay-set:<n>                 every checked row proved both ends
#   blocked:replay-set:<k>-of-<n>     k rows failed (each printed as bad:<order>:<reason>)
#   could-not-run:replay-set:<why>    data file or git history unavailable
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="${REPLAY_SET_DATA:-$HERE/replay-set.tsv}"
BASE_REF="${REPLAY_SET_BASE_REF:-${TILLANDSIAS_GATE_DIFF_BASE:-origin/linux-next}}"
TIMEOUT_S="${REPLAY_SET_TIMEOUT_S:-300}"

[ -r "$DATA" ] || { echo "could-not-run:replay-set:no-data-file:$DATA"; exit 3; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "could-not-run:replay-set:not-a-git-checkout"; exit 3; }

LIST=0
WANT=" "
NEXT_IS_DATA=0
for a in "$@"; do
    if [ "$NEXT_IS_DATA" = 1 ]; then DATA="$a"; NEXT_IS_DATA=0; continue; fi
    case "$a" in
        --list) LIST=1 ;;
        --data) NEXT_IS_DATA=1 ;;
        *) WANT="$WANT$a " ;;
    esac
done
[ -r "$DATA" ] || { echo "could-not-run:replay-set:no-data-file:$DATA"; exit 3; }

# Row count is asserted, not assumed: a data file that parses to nothing must
# not print a green verdict (a guard must assert its population).
total=0; checked=0; badn=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/replay-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# The closures run litmus in trees under $WORK, which are not checkouts, so the
# runner's timing log would fall back to the shared /tmp/tillandsias-timing.jsonl
# and a concurrent gate step on this host is refused for "writing" it (1204-3s2s;
# evicted #606 on macuahuitl 2026-10-23). Keep every record in our own scratch.
export TILLANDSIAS_TIMING_LOG="$WORK/timing.jsonl"

run_closure() { # run_closure <dir> <command> -> exit status of the command
    ( cd "$1" && timeout "$TIMEOUT_S" bash -c "$2" >"$WORK/out.log" 2>&1 </dev/null )
}

while IFS=$'\t' read -r order landed prefix overlay owned cmd; do
    case "$order" in ''|'#'*) continue ;; esac
    total=$((total + 1))
    if [ "$LIST" = 1 ]; then
        echo "$order $landed $prefix $cmd"
        continue
    fi
    case "$WANT" in " "|*" $order "*) ;; *) continue ;; esac
    checked=$((checked + 1))

    if ! git merge-base --is-ancestor "$landed" "$BASE_REF" 2>/dev/null; then
        echo "bad:$order:${landed:0:9}:landed-sha-not-ancestor-of-$BASE_REF"; badn=$((badn + 1)); continue
    fi
    if [ "$(git rev-parse "$landed^" 2>/dev/null)" != "$(git rev-parse "$prefix" 2>/dev/null)" ]; then
        echo "bad:$order:${landed:0:9}:prefix-is-not-the-landed-commits-parent"; badn=$((badn + 1)); continue
    fi

    pre="$WORK/pre"; post="$WORK/post"
    chmod -R u+w "$pre" "$post" 2>/dev/null; rm -rf "$pre" "$post"; mkdir -p "$pre" "$post"
    git archive "$prefix" </dev/null | tar -x -C "$pre"
    git archive "$landed" | tar -x -C "$post"
    # Only files the landed tree still has: a fixture the landing deleted is
    # not part of what the delegate must make green.
    keep=""
    for of in $overlay; do
        git cat-file -e "$landed:$of" 2>/dev/null && keep="$keep $of"
    done
    if [ -n "$keep" ]; then
        # shellcheck disable=SC2086
        git archive "$landed" -- $keep | tar -x -C "$pre"
    fi

    # Many fixtures ask `git rev-parse` of their cwd; an archive has no .git.
    # A throwaway one-commit repo answers that without touching real history.
    for d in "$pre" "$post"; do
        ( cd "$d" && git init -q . && git add -A >/dev/null 2>&1 \
            && git -c user.name=replay -c user.email=replay@invalid commit -qm replay >/dev/null 2>&1 )
    done

    if run_closure "$pre" "$cmd"; then
        echo "bad:$order:${landed:0:9}:closure-passes-on-the-pre-fix-tree"; badn=$((badn + 1)); continue
    fi
    if ! run_closure "$post" "$cmd"; then
        echo "bad:$order:${landed:0:9}:closure-fails-on-the-landed-tree:$(tail -n 1 "$WORK/out.log" | cut -c1-120)"
        badn=$((badn + 1)); continue
    fi
    echo "ok:$order:${landed:0:9}"
done < "$DATA"

[ "$LIST" = 1 ] && exit 0
if [ "$total" -eq 0 ] || [ "$checked" -eq 0 ]; then
    echo "could-not-run:replay-set:no-rows-checked(total=$total)"; exit 3
fi
if [ "$badn" -gt 0 ]; then
    echo "blocked:replay-set:$badn-of-$checked"
    echo "  why: each bad:<order>:<sha>:<reason> line above names a row whose closure does not separate its pre-fix tree from its landed tree" >&2
    echo "  remedy: fix or drop that row in replay-set.tsv (pick a different landed commit or closure), then re-run verify-set.sh <order>" >&2
    exit 1
fi
echo "ok:replay-set:$checked"
