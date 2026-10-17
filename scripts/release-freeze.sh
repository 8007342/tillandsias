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
# LANDING THE CUT'S OWN FIX (order 1265-8qr6). The hook refuses the cut host's
# own code push exactly as it refuses everyone's, so the only sequence was
# clear -> land -> set, and for the whole land (gate included) `ls-remote`
# returned NOTHING and `status` read ok:freeze-none — a true answer every host
# was told to treat as "push". MEASURED on pirria-silverblue 2026-09-19: 42
# consecutive clear samples across 7m26s of one such land. `land` replaces it:
# it writes a SUCCESSOR marker first,
#
#   refs/tillandsias/freeze-landing/<branch>/<host>/<epoch>
#
# and only then deletes the freeze marker, and `set` re-freezes the same way
# round (freeze marker first, then the landing marker goes). So the marker set
# is never empty during a legitimate land, and `status` reads
# frozen-landing:<branch>:by=<host> — "frozen, landing by <host>" — instead of
# an absence. The landing marker is in its own namespace, which the pre-push
# hook, the land queue and release-preflight do not read (they glob
# refs/tillandsias/freeze/*), so the landing host's push goes through.
# NO CUT-HOST EXEMPTION (coordinator ruling 2026-10-16): the freeze is a
# coordination signal, not an authentication boundary. Host identity at push
# time is self-declared, so a hook admitting "the host the marker names" would
# admit any host that names itself; an exemption whose conditions cannot be
# verified only looks like a boundary. During a land, a host reading
# frozen-landing holds its code exactly as it would for frozen.
#
# VERDICTS (stdout, last line):
#   ok:freeze-set:<ref>                       the branch is now frozen
#   ok:freeze-already:<ref>                   a live marker for this branch already exists
#   ok:freeze-cleared:<n>                     n marker(s) removed (0 is not an error)
#   ok:freeze-landing:<ref>                   land: the successor marker is set and
#                                             the freeze marker removed
#   ok:freeze-landing-already:<ref>           land: already landing, nothing changed
#   ok:freeze-none:<branch>                   status: not frozen
#   frozen:<branch>:by=<host>:since=<epoch>:age=<n>s     status: frozen
#   frozen-landing:<branch>:by=<host>:since=<epoch>:age=<n>s
#                                             status: frozen, a fix landing by <host>
#   refused:freeze:not-frozen:<branch>        land: there is no freeze to hand over
#   refused:freeze:usage:<detail>             bad arguments
#   refused:freeze:no-such-branch:<branch>    the branch does not exist on the remote
#   refused:freeze:unreachable:<detail>       the remote could not be queried, fetched
#                                             from or pushed to; <detail> carries
#                                             git's own refusal lines (1422-fvce)
#
# AUDIT (order 1255-s4im) — the server-visible half. The hook refuses a frozen
# push only on a host whose hook is armed, and `--no-verify`, a redirected
# hooksPath or a host that never installed hooks bypasses it by construction.
# But the marker POINTS AT THE BRANCH TIP AS FROZEN, so what arrived during the
# freeze is simply `<marker target>..<branch tip>`. `audit` reads origin only
# through ls-remote and fetch, so it gives the same answer from ANY host, hooked
# or not, and it names every commit that brought a held path in:
#   ok:freeze-none:<branch>                                  not frozen
#   ok:freeze-audit:clean:<branch>:moved=<n>                 nothing held arrived
#   breach:<branch>:<sha>:<author>:<subject>                 one per offending commit
#   held:<path>                                              each held path (first 20)
#   violation:freeze-breached:<branch>:commits=<n>:held-paths=<k>:frozen-at=<sha>:tip=<sha>   exit 1
#   refused:freeze:unreachable:<detail>                      exit 3 — could not ask
# `status` prints the audit verdict on stderr when the branch is frozen.
set -euo pipefail

# The freeze predicate and the marker read are shared with the hook,
# release-preflight and land-queue (1255-s4im), so they cannot disagree.
# shellcheck source=lib-freeze-paths.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-freeze-paths.sh"

NS="refs/tillandsias/freeze"

_usage() {
    cat >&2 <<'USAGE'
usage: scripts/release-freeze.sh set <branch> [reason] | land <branch> | clear <branch> | status <branch> | audit <branch>
       [--remote <name>]   (default: origin)
  set     declare a freeze on <branch>; code pushes to it are refused by the pre-push hook.
          After a `land`, this is the re-freeze: the freeze marker is written
          before the landing marker is removed
  land    hand a freeze over to the cut's own fix: write the landing marker, THEN
          remove the freeze marker, so <branch> reads frozen-landing, never clear
  clear   remove every freeze and landing marker for <branch>, whoever set it
  status  report whether <branch> is frozen, by whom, and for how long
  audit   name every commit that brought a held path into <branch> since it froze
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
    set|land|clear|status|audit) ;;
    *) _usage; echo "refused:freeze:usage:${CMD:-<no command>}"; exit 2 ;;
esac
if [ -z "$BRANCH" ]; then
    _usage; echo "refused:freeze:usage:<branch> is required"; exit 2
fi
# The ref name encodes host and epoch after the branch, so a branch containing
# a slash would make the name ambiguous to parse back. Freezes are declared on
# trunk-shaped branches; refuse rather than mis-parse.
case "$BRANCH" in
    */*) echo "refused:freeze:usage:branch '$BRANCH' contains a slash; freezes are declared on trunk-shaped branches"
         printf '  why: the marker ref encodes <branch>/<host>/<epoch>, so a slash in the branch could not be parsed back\n  remedy: freeze the trunk-shaped branch the cut gates (usually linux-next)\n' >&2
         exit 2 ;;
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

# git's own words on one line (1422-fvce). A push runs the pre-push hook, whose
# chatter precedes git's refusal, so keep the lines git refuses WITH — remote:,
# " ! ", error:, fatal:, and any refused/declined/rejected line — and fall back
# to the last three non-empty lines when none match.
_git_reason() {
    local why
    why="$(printf '%s\n' "$1" | awk 'NF && (/^(remote:|error:|fatal:| ! )/ || /refused|declined|rejected/)')"
    [ -n "$why" ] || why="$(printf '%s\n' "$1" | awk 'NF' | tail -3)"
    printf '%s' "$why" | tr '\n' ' ' | sed 's/  */ /g; s/ $//'
}

_afford() { printf '  why: %s\n  remedy: %s\n' "$1" "$2" >&2; }

# The marker read itself failed: whether <branch> is frozen is unknown, never
# "not frozen" (1265-8qr6 reads both namespaces, so either can fail).
_ls_unreachable() {
    echo "refused:freeze:unreachable:git ls-remote $REMOTE failed or timed out"
    _afford "$REMOTE did not answer the marker read, so whether $BRANCH is frozen or landing is unknown — never read as clear" \
        "check the network and credentials for $REMOTE (git ls-remote $REMOTE), then re-run scripts/release-freeze.sh $CMD $BRANCH"
}

_markers() { # -> "<sha>\t<ref>" lines, oldest first, empty when not frozen
    freeze_markers "$REMOTE" "$BRANCH"
}

LNS="refs/tillandsias/freeze-landing"
# The landing markers (1265-8qr6), same shape and order as _markers. Read only
# here: the hook, the land queue and release-preflight never see them.
_landings() {
    local out
    out="$(_t 10 git ls-remote "$REMOTE" "$LNS/$BRANCH/*" 2>/dev/null)" || return 1
    [ -n "$out" ] || return 0
    printf '%s\n' "$out" | awk -F'\t' '{ n = split($2, p, "/"); print p[n] "\t" $0 }' \
        | sort -n | cut -f2-
}

# "<prefix>:<branch>:by=<host>:since=<epoch>:age=<n>s" for the first marker in $2
# under namespace $3.
_who_line() {
    local ref rest who when now age
    ref="$(printf '%s\n' "$2" | head -1 | cut -f2)"
    rest="${ref#"$3/$BRANCH/"}"
    who="${rest%%/*}"; when="${rest##*/}"
    now="$(date -u +%s)"
    case "$when" in ''|*[!0-9]*) age="unknown" ;; *) age="$((now - when))s" ;; esac
    printf '%s:%s:by=%s:since=%s:age=%s\n' "$1" "$BRANCH" "$who" "$when" "$age"
}

# Delete every ref in a "<sha>\t<ref>" list, one "cleared: <ref>" per ref on
# stderr; prints the count on stdout. On the first ref that will not go it
# prints "failed: <ref>" on stderr and returns 1.
_delete_all() {
    local n=0 line r
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        r="$(printf '%s' "$line" | cut -f2)"
        if _t 30 git push --quiet "$REMOTE" --delete "$r" 2>/dev/null; then
            n=$((n+1)); echo "cleared: $r" >&2
        else
            echo "failed: $r" >&2; printf '%s' "$n"; return 1
        fi
    done <<REFS
$1
REFS
    printf '%s' "$n"
}

# The audit body (1255-s4im). Prints its lines and verdict on stdout and
# returns 0 clean/none, 1 breach, 3 could-not-ask.
_audit() {
    local out rc oldest frozen_at ref tip held n k moved commits paths p
    rc=0; out="$(_markers)" || rc=$?
    if [ "$rc" -ne 0 ]; then echo "refused:freeze:unreachable:git ls-remote $REMOTE failed or timed out"; _afford "$REMOTE did not answer, so whether the freeze held is unknown — never clean (1255-s4im)" "check the network and credentials for $REMOTE (git ls-remote $REMOTE), then re-run scripts/release-freeze.sh audit $BRANCH"; return 3; fi
    if [ -z "$out" ]; then
        # A land in progress (1265-8qr6) is not "no freeze": say so.
        rc=0; out="$(_landings)" || rc=$?
        if [ "$rc" -eq 0 ] && [ -n "$out" ]; then _who_line ok:freeze-landing "$out" "$LNS"; return 0; fi
        echo "ok:freeze-none:$BRANCH"; return 0
    fi
    # The OLDEST marker is when the freeze began; a later marker cannot excuse
    # what arrived between the two.
    oldest="$(printf '%s\n' "$out" | head -n 1)"
    frozen_at="$(printf '%s' "$oldest" | cut -f1)"; ref="$(printf '%s' "$oldest" | cut -f2)"
    rc=0; tip="$(_t 10 git ls-remote "$REMOTE" "refs/heads/$BRANCH" 2>/dev/null | cut -f1)" || rc=$?
    if [ "$rc" -ne 0 ]; then echo "refused:freeze:unreachable:git ls-remote $REMOTE failed or timed out"; _afford "$REMOTE did not answer, so whether the freeze held is unknown — never clean (1255-s4im)" "check the network and credentials for $REMOTE (git ls-remote $REMOTE), then re-run scripts/release-freeze.sh audit $BRANCH"; return 3; fi
    if [ -z "$tip" ]; then echo "refused:freeze:unreachable:$BRANCH is gone from $REMOTE while $ref still marks it"; _afford "a freeze marker names $BRANCH but $REMOTE has no such branch, so there is nothing to compare the freeze against" "if the branch was deleted on purpose, clear the stale marker: scripts/release-freeze.sh clear $BRANCH"; return 3; fi
    if [ "$tip" = "$frozen_at" ]; then echo "ok:freeze-audit:clean:$BRANCH:moved=0"; return 0; fi
    # Both objects from origin itself, so every host computes the same answer.
    if ! git cat-file -e "$frozen_at^{commit}" 2>/dev/null || ! git cat-file -e "$tip^{commit}" 2>/dev/null; then
        rc=0; err="$(_t 60 git fetch --quiet "$REMOTE" "refs/heads/$BRANCH" "$ref" 2>&1)" || rc=$?
        if [ "$rc" -ne 0 ] || ! git cat-file -e "$frozen_at^{commit}" 2>/dev/null || ! git cat-file -e "$tip^{commit}" 2>/dev/null; then
            echo "refused:freeze:unreachable:could not fetch $BRANCH and $ref from $REMOTE: $(_git_reason "${err:-}")"; _afford "$REMOTE did not answer, so whether the freeze held is unknown — never clean (1255-s4im)" "check the network and credentials for $REMOTE (git ls-remote $REMOTE), then re-run scripts/release-freeze.sh audit $BRANCH"; return 3
        fi
    fi
    moved="$(git rev-list --count "$frozen_at..$tip" 2>/dev/null || echo '?')"
    held="$(freeze_held_paths "$frozen_at" "$tip")"
    if [ -z "$held" ]; then echo "ok:freeze-audit:clean:$BRANCH:moved=$moved"; return 0; fi
    k="$(printf '%s\n' "$held" | wc -l | tr -d ' ')"
    paths=()
    while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done <<HELD
$held
HELD
    commits="$(git log --format='%h%x09%an%x09%s' "$frozen_at..$tip" -- "${paths[@]}" 2>/dev/null)"
    n=0
    while IFS=$'\t' read -r c a subj; do
        [ -n "$c" ] || continue
        n=$((n + 1))
        echo "breach:$BRANCH:$c:$a:$subj"
    done <<COMMITS
$commits
COMMITS
    printf '%s\n' "$held" | head -n 20 | sed 's/^/held:/'
    if ! git merge-base --is-ancestor "$frozen_at" "$tip" 2>/dev/null; then
        echo "  note: $BRANCH no longer contains its freeze-time tip ${frozen_at:0:12} (rewritten while frozen)" >&2
    fi
    echo "  why: $BRANCH was frozen at ${frozen_at:0:12} ($ref) and $n commit(s) since then brought in $k path(s) the freeze holds; a cut gated before they arrived does not describe the tree that would ship" >&2
    echo "  remedy: either revert the breach (git revert the commits named above; the audit then reads clean), or re-gate the cut from the new tip ${tip:0:12} and re-freeze there (scripts/release-freeze.sh clear $BRANCH && scripts/release-freeze.sh set $BRANCH) — either clears it, and neither needs the operator" >&2
    echo "violation:freeze-breached:$BRANCH:commits=$n:held-paths=$k:frozen-at=${frozen_at:0:12}:tip=${tip:0:12}"
    return 1
}

case "$CMD" in
    status)
        rc=0; out="$(_markers)" || rc=$?
        if [ "$rc" -ne 0 ]; then _ls_unreachable; exit 1; fi
        if [ -z "$out" ]; then
            rc=0; out="$(_landings)" || rc=$?
            if [ "$rc" -ne 0 ]; then _ls_unreachable; exit 1; fi
            if [ -n "$out" ]; then
                # Frozen, the cut's own fix landing (1265-8qr6): hold code as
                # for frozen; the freeze returns when the land does.
                _who_line frozen-landing "$out" "$LNS"; exit 0
            fi
            echo "ok:freeze-none:$BRANCH"; exit 0
        fi
        _who_line frozen "$out" "$NS"
        # 1255-s4im: say whether the freeze has held, on stderr so the status
        # grammar (one stdout line) is unchanged.
        _audit 2>&1 | sed 's/^/  audit: /' >&2 || true
        exit 0
        ;;
    audit)
        rc=0; _audit || rc=$?
        exit "$rc"
        ;;
    set)
        rc=0; out="$(_markers)" || rc=$?
        [ "$rc" -eq 0 ] || { _ls_unreachable; exit 1; }
        if [ -n "$out" ]; then
            echo "ok:freeze-already:$(printf '%s\n' "$out" | head -1 | cut -f2)"; exit 0
        fi
        rc=0; tip="$(_t 10 git ls-remote "$REMOTE" "refs/heads/$BRANCH" 2>/dev/null | cut -f1)" || rc=$?
        [ "$rc" -eq 0 ] || { _ls_unreachable; exit 1; }
        if [ -z "$tip" ]; then
            echo "refused:freeze:no-such-branch:$BRANCH"
            _afford "$REMOTE has no branch $BRANCH, so there is no tip to freeze" \
                "name the branch the cut gates (usually linux-next): scripts/release-freeze.sh set <branch>"
            exit 1
        fi
        ref="$NS/$BRANCH/$(_host)/$(date -u +%s)"
        # 1422-fvce: the tip comes from ls-remote, so when the branch moved since
        # this clone last fetched, the object is not local and `git push` cannot
        # send it. Fetch it first. And keep git's stderr: discarding it turned
        # every push failure into a bare "could not push", a STOP in the release
        # runbook that named nothing.
        if ! git cat-file -e "$tip^{commit}" 2>/dev/null; then
            rc=0; err="$(_t 30 git fetch --quiet "$REMOTE" "refs/heads/$BRANCH" 2>&1)" || rc=$?
            if [ "$rc" -ne 0 ] || ! git cat-file -e "$tip^{commit}" 2>/dev/null; then
                echo "refused:freeze:unreachable:could not fetch $BRANCH@${tip:0:12} from $REMOTE: $(_git_reason "$err")"
                _afford "the marker must point at $BRANCH's tip, and this clone could not fetch it, so no freeze was declared" \
                    "fix what git said above (network or credentials for $REMOTE), then re-run scripts/release-freeze.sh set $BRANCH; until then the branch is NOT frozen"
                exit 1
            fi
        fi
        rc=0; err="$(_t 30 git push --quiet "$REMOTE" "$tip:$ref" 2>&1)" || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "refused:freeze:unreachable:could not push the marker to $REMOTE: $(_git_reason "$err")"
            _afford "$REMOTE refused the freeze marker push, so no freeze was declared" \
                "fix what git said above (credentials, or a pre-push refusal), then re-run scripts/release-freeze.sh set $BRANCH; until then the branch is NOT frozen"
            exit 1
        fi
        # The re-freeze after a land (1265-8qr6): the landing marker goes only
        # now, AFTER the freeze marker is on origin, so the set is never empty.
        # A landing marker that will not go is harmless (status reads the
        # freeze first), so it is named and the freeze still stands.
        rc=0; landed="$(_landings)" || rc=$?
        if [ "$rc" -eq 0 ] && [ -n "$landed" ]; then
            _delete_all "$landed" >/dev/null 2>&1 \
                || echo "  note: a landing marker for $BRANCH did not delete; clear it with scripts/release-freeze.sh clear $BRANCH at the end of the cut" >&2
        fi
        [ -n "$REASON" ] && echo "freeze reason: $REASON" >&2
        echo "the branch is frozen for CODE pushes; plan-only pushes stay admitted" >&2
        echo "clear it at the back-merge push: scripts/release-freeze.sh clear $BRANCH" >&2
        echo "ok:freeze-set:$ref"
        ;;
    land)
        rc=0; out="$(_markers)" || rc=$?
        [ "$rc" -eq 0 ] || { _ls_unreachable; exit 1; }
        if [ -z "$out" ]; then
            rc=0; landed="$(_landings)" || rc=$?
            [ "$rc" -eq 0 ] || { _ls_unreachable; exit 1; }
            if [ -n "$landed" ]; then
                echo "ok:freeze-landing-already:$(printf '%s\n' "$landed" | head -1 | cut -f2)"; exit 0
            fi
            echo "refused:freeze:not-frozen:$BRANCH"
            _afford "$BRANCH has no freeze marker on $REMOTE, so there is no freeze to hand over to a landing" \
                "push the fix the ordinary way; to freeze first, run scripts/release-freeze.sh set $BRANCH"
            exit 1
        fi
        # SUCCESSOR FIRST (1265-8qr6). The landing marker points at the same
        # commit as the freeze marker (already on origin, so nothing uploads),
        # and the freeze marker goes only once it is there.
        sha="$(printf '%s\n' "$out" | head -1 | cut -f1)"
        ref="$LNS/$BRANCH/$(_host)/$(date -u +%s)"
        rc=0; err="$(_t 30 git push --quiet "$REMOTE" "$sha:$ref" 2>&1)" || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "refused:freeze:unreachable:could not push the landing marker to $REMOTE (the freeze still stands): $(_git_reason "$err")"
            _afford "$REMOTE refused the landing marker push; the freeze marker was left in place, so the branch is still frozen and still refuses this land" \
                "fix what git said above, then re-run scripts/release-freeze.sh land $BRANCH"
            exit 1
        fi
        rc=0; _delete_all "$out" >/dev/null || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "refused:freeze:unreachable:the landing marker is set but a freeze marker would not delete, so the freeze still holds this land"
            _afford "$REMOTE refused deleting the freeze marker for $BRANCH named above" \
                "re-run scripts/release-freeze.sh land $BRANCH; it keeps the landing marker and retries the delete"
            exit 1
        fi
        echo "$BRANCH reads frozen-landing until the fix lands; re-freeze then: scripts/release-freeze.sh set $BRANCH" >&2
        echo "ok:freeze-landing:$ref"
        ;;
    clear)
        rc=0; out="$(_markers)" || rc=$?
        [ "$rc" -eq 0 ] || { _ls_unreachable; exit 1; }
        rc=0; landed="$(_landings)" || rc=$?
        [ "$rc" -eq 0 ] || { _ls_unreachable; exit 1; }
        all="$(printf '%s\n%s\n' "$out" "$landed" | awk 'NF')"
        if [ -z "$all" ]; then echo "ok:freeze-cleared:0"; exit 0; fi
        rc=0; n="$(_delete_all "$all")" || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "refused:freeze:unreachable:could not delete the marker named above"
            _afford "$REMOTE refused deleting a marker for $BRANCH (the failed: line above), so some markers may remain" \
                "re-run scripts/release-freeze.sh clear $BRANCH; it deletes whatever is left"
            exit 1
        fi
        echo "ok:freeze-cleared:$n"
        ;;
esac
