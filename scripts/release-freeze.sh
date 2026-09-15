#!/usr/bin/env bash
# release-freeze.sh — set, clear and read the LIVE freeze marker a cut declares
# (order 1176-9vqn).
#
# THE DEFECT THIS CLOSES. A release freeze was announced in ledger prose and
# enforced by NOTHING. MEASURED on yolanda during the v56.9.13.1 cut: a merge
# carrying a claim event that itself said "code held until the all-clear" was
# followed by a 2476 s gate and a push, and every pre-push check passed —
# because none of them is about a freeze. That push was harmless only because
# it went to windows-next, a branch the release gate does not read; the same
# sequence aimed at linux-next would have pushed code into the frozen branch
# with every check green. Nothing in the system knew either way.
#
# WHY A MARKER ON ORIGIN AND NOT A LOCAL FILE. A local file is only as fresh as
# the last fetch, which reintroduces the window one layer down. THE WINDOW IS
# THE MECHANISM: `./build.sh --check` takes 41 minutes on yolanda and longer on
# the floor, so a freeze declared inside that window is invisible to a land
# that checked before it started, and the land pushes on completion without
# re-asking. "Check before you push" is not a rule anyone can follow here. The
# check has to happen AT the push, against origin.
#
# REF SHAPE, following the convention the credential mirror already uses
# (refs/tillandsias/upstream-auth/...):
#
#   refs/tillandsias/freeze/<branch>/<host>/<epoch>
#
# The NAME carries who froze it and when, so one `git ls-remote` answers
# "is it frozen, by whom, since when" without fetching an object. The ref
# points at the frozen branch's tip AS IT STOOD AT FREEZE TIME, which is
# already on the remote — so setting a freeze uploads nothing.
#
# LIFETIME: the cut runbook sets the marker at gate start and clears it at the
# back-merge push, so the marker's lifetime IS the freeze's lifetime and nobody
# has to remember to clear it. `clear` removes every marker for the branch,
# whoever set it, so a coordinator can always clear a freeze another host set.
#
# VERDICTS (stdout, last line):
#   ok:freeze-set:<ref>                       the branch is now frozen
#   ok:freeze-already:<ref>                   a live marker for this branch already exists
#   ok:freeze-cleared:<n>                     n marker(s) removed (0 is not an error)
#   ok:freeze-none:<branch>                   status: not frozen
#   frozen:<branch>:by=<host>:since=<epoch>:age=<n>s     status: frozen
#   refused:freeze:usage:<detail>             bad arguments
#   refused:freeze:no-such-branch:<branch>    the branch does not exist on the remote
#   refused:freeze:unreachable:<detail>       the remote could not be queried
set -euo pipefail

NS="refs/tillandsias/freeze"

_usage() {
    cat >&2 <<'USAGE'
usage: scripts/release-freeze.sh set <branch> [reason] | clear <branch> | status <branch>
       [--remote <name>]   (default: origin)
  set     declare a freeze on <branch>; code pushes to it are refused by the pre-push hook
  clear   remove every freeze marker for <branch>, whoever set it
  status  report whether <branch> is frozen, by whom, and for how long
A freeze holds CODE pushes only. Plan-only pushes stay admitted by design:
the plan lane is how coordination keeps moving during a cut.
USAGE
}

REMOTE="origin"
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --remote) REMOTE="${2:-}"; shift 2 ;;
        -h|--help) _usage; exit 0 ;;
        -*) _usage; echo "refused:freeze:usage:$1"; exit 2 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
CMD="${1:-}"; BRANCH="${2:-}"; REASON="${3:-}"
case "$CMD" in
    set|clear|status) ;;
    *) _usage; echo "refused:freeze:usage:${CMD:-<no command>}"; exit 2 ;;
esac
if [ -z "$BRANCH" ]; then
    _usage; echo "refused:freeze:usage:<branch> is required"; exit 2
fi
# The ref name encodes host and epoch after the branch, so a branch containing
# a slash would make the name ambiguous to parse back. Freezes are declared on
# trunk-shaped branches; refuse rather than mis-parse.
case "$BRANCH" in
    */*) echo "refused:freeze:usage:branch '$BRANCH' contains a slash; freezes are declared on trunk-shaped branches"; exit 2 ;;
esac

_host() {
    local h
    h="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
    h="$(printf '%s' "$h" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
    [ -n "$h" ] || h="unknown"
    printf '%s' "$h"
}

# Bounded, so a hung network cannot hang the caller. Same shape as
# check-credential-channel.sh's _ccc_timeout.
_t() {
    local s="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
    else "$@"; fi
}

_markers() { # -> "<sha>\t<ref>" lines, empty when not frozen
    _t 10 git ls-remote "$REMOTE" "$NS/$BRANCH/*" 2>/dev/null || return 1
}

case "$CMD" in
    status)
        rc=0; out="$(_markers)" || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "refused:freeze:unreachable:git ls-remote $REMOTE failed or timed out"; exit 1
        fi
        if [ -z "$out" ]; then echo "ok:freeze-none:$BRANCH"; exit 0; fi
        ref="$(printf '%s\n' "$out" | head -1 | cut -f2)"
        rest="${ref#"$NS/$BRANCH/"}"
        who="${rest%%/*}"; when="${rest##*/}"
        now="$(date -u +%s)"
        case "$when" in ''|*[!0-9]*) age="unknown" ;; *) age="$((now - when))s" ;; esac
        printf 'frozen:%s:by=%s:since=%s:age=%s\n' "$BRANCH" "$who" "$when" "$age"
        exit 0
        ;;
    set)
        rc=0; out="$(_markers)" || rc=$?
        [ "$rc" -eq 0 ] || { echo "refused:freeze:unreachable:git ls-remote $REMOTE failed or timed out"; exit 1; }
        if [ -n "$out" ]; then
            echo "ok:freeze-already:$(printf '%s\n' "$out" | head -1 | cut -f2)"; exit 0
        fi
        rc=0; tip="$(_t 10 git ls-remote "$REMOTE" "refs/heads/$BRANCH" 2>/dev/null | cut -f1)" || rc=$?
        [ "$rc" -eq 0 ] || { echo "refused:freeze:unreachable:git ls-remote $REMOTE failed or timed out"; exit 1; }
        [ -n "$tip" ] || { echo "refused:freeze:no-such-branch:$BRANCH"; exit 1; }
        ref="$NS/$BRANCH/$(_host)/$(date -u +%s)"
        if ! _t 30 git push --quiet "$REMOTE" "$tip:$ref" 2>/dev/null; then
            echo "refused:freeze:unreachable:could not push the marker to $REMOTE"; exit 1
        fi
        [ -n "$REASON" ] && echo "freeze reason: $REASON" >&2
        echo "the branch is frozen for CODE pushes; plan-only pushes stay admitted" >&2
        echo "clear it at the back-merge push: scripts/release-freeze.sh clear $BRANCH" >&2
        echo "ok:freeze-set:$ref"
        ;;
    clear)
        rc=0; out="$(_markers)" || rc=$?
        [ "$rc" -eq 0 ] || { echo "refused:freeze:unreachable:git ls-remote $REMOTE failed or timed out"; exit 1; }
        if [ -z "$out" ]; then echo "ok:freeze-cleared:0"; exit 0; fi
        n=0
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            r="$(printf '%s' "$line" | cut -f2)"
            if _t 30 git push --quiet "$REMOTE" --delete "$r" 2>/dev/null; then
                n=$((n+1)); echo "cleared: $r" >&2
            else
                echo "refused:freeze:unreachable:could not delete $r"; exit 1
            fi
        done <<EOF
$out
EOF
        echo "ok:freeze-cleared:$n"
        ;;
esac
