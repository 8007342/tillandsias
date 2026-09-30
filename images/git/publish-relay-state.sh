#!/bin/sh
# @trace spec:git-mirror-service
# @trace order:1310-rec6
#
# publish-relay-state.sh <bare-mirror-dir>
#
# 1310-rec6 STEP 2: what BROKEN means, in the mirror's own terms (spec accepted
# by the coordinator 2026-09-30, recorded on the row).
#
# RUNS ON THE RECONCILE TICK, AFTER THE TICK'S FETCH has refreshed
# refs/remotes/origin/*. That ordering is the definition, not a detail:
# measured on lenovinha, a head pushed through the host lane sat one commit
# AHEAD of its tracking ref until the next fetch, because the relay updates
# GitHub first and the tracking namespace only on fetch. Judged on a stale
# tracking ref, every successful push would read as unrelayed.
#
# A head is a CANDIDATE when it is ahead of, or absent from, its tracking ref.
# Each candidate is RETRIED through the mirror's own relay helper (the same
# path the startup sweep uses): N=3 attempts inside ONE tick, backoff
# 2 s / 8 s / 30 s (RELAY_STATE_BACKOFF), scaled down when the tick is shorter
# than 60 s so a bad tick never runs into the next. A retry that succeeds
# means the head was merely not yet fetched: not broken.
#
# A retry that fails is classified by the LAYER that failed:
#   credential  the credential was refused or could not be read
#   transport   upstream could not be reached
#   rejection   upstream was reached and refused THIS ref
# credential and transport are mirror faults; rejection is per-ref and never
# makes the mirror broken (one bad ref must not take a healthy mirror off the
# air).
#
# HYSTERESIS: credential/transport must fail on 2 CONSECUTIVE ticks before the
# state is `broken` (step 3 withdraws the advertisement on broken); the first
# failing tick is `degraded`; one ok tick restores `ok`. The SAME ref rejected
# on 3 consecutive ticks publishes loudly as stuck-ref.
#
# PUBLISHES, atomically, in the upstream-auth / sync-state / discipline shape:
#   refs/tillandsias/relay-state/<ok|degraded|broken>/<class|none>/<n-refs>/<epoch>
#   refs/tillandsias/relay-state-stuck/<ref-sha1>/<epoch>   one per stuck ref
# Each points at the empty blob; the PATH carries the message (ls-remote).
set -u
MIRROR="${1:-}"
[ -n "$MIRROR" ] && [ -d "$MIRROR" ] || { echo "publish-relay-state: usage: publish-relay-state <bare-mirror-dir>" >&2; exit 2; }
RELAY="${RELAY_REF:-$MIRROR/hooks/tillandsias-relay-refs}"
TICK="${MIRROR_RECONCILE_INTERVAL:-120}"
BACKOFF="${RELAY_STATE_BACKOFF:-2 8 30}"
if [ "$TICK" -lt 60 ] 2>/dev/null; then BACKOFF="1 2 4"; fi
STATE_FILE="$MIRROR/tillandsias-relay-state"   # hysteresis memory across ticks
NS="refs/tillandsias/relay-state"
NS_STUCK="refs/tillandsias/relay-state-stuck"
TMP="$(mktemp -d 2>/dev/null || mktemp -d -t relay-state)"
trap 'rm -rf "$TMP"' EXIT

classify() {   # <relay output>: credential | transport | rejection
    case "$1" in
        *"Authentication failed"*|*"could not read Username"*|*"HTTP 401"*|*"HTTP 403"*|*"denied to"*|*"Permission to "*|*"agent-unauthenticated"*|*"invalid credentials"*)
            echo credential ;;
        *"[rejected]"*|*"non-fast-forward"*|*"protected branch"*|*"pre-receive hook declined"*|*"[remote rejected]"*|*"GH006"*|*"GH013"*)
            echo rejection ;;
        *) echo transport ;;
    esac
}

# Previous tick's memory: fails=<consecutive mirror-fault ticks> class=<c>,
# and one line per rejected ref with its consecutive count.
prev_fails=0; prev_class=none
[ -r "$STATE_FILE" ] && {
    prev_fails="$(sed -n 's/^fails=//p' "$STATE_FILE" | head -n 1)"; prev_fails="${prev_fails:-0}"
    prev_class="$(sed -n 's/^class=//p' "$STATE_FILE" | head -n 1)"; prev_class="${prev_class:-none}"
    grep '^rejected ' "$STATE_FILE" > "$TMP/prev-rejected" 2>/dev/null || true
}
: > "$TMP/prev-rejected.x"; [ -f "$TMP/prev-rejected" ] || : > "$TMP/prev-rejected"

fault_class=none; faults=0
: > "$TMP/rejected"
for ref in $(git -C "$MIRROR" for-each-ref --format='%(refname)' refs/heads 2>/dev/null); do
    short="${ref#refs/heads/}"
    track="refs/remotes/origin/$short"
    if git -C "$MIRROR" rev-parse --verify --quiet "$track" >/dev/null 2>&1; then
        ahead="$(git -C "$MIRROR" rev-list --count "$track..$ref" 2>/dev/null || echo 0)"
        [ "${ahead:-0}" -gt 0 ] || continue
    fi
    sha="$(git -C "$MIRROR" rev-parse "$ref")"
    ok=no; out=""
    for wait in $BACKOFF; do
        if out="$(printf '%s %s %s\n' "$sha" "$sha" "$ref" | (cd "$MIRROR" && "$RELAY") 2>&1)"; then ok=yes; break; fi
        sleep "$wait"
    done
    [ "$ok" = yes ] && continue
    c="$(classify "$out")"
    if [ "$c" = rejection ]; then
        n="$(awk -v r="$ref" '$2 == r { print $3 }' "$TMP/prev-rejected")"
        printf 'rejected %s %s\n' "$ref" "$(( ${n:-0} + 1 ))" >> "$TMP/rejected"
    else
        faults=$((faults + 1))
        # credential outranks transport: it is the one an operator must act on
        [ "$c" = credential ] || [ "$fault_class" = credential ] && fault_class=credential || fault_class=transport
    fi
done

if [ "$faults" -gt 0 ]; then
    fails=$((prev_fails + 1))
    if [ "$fails" -ge 2 ]; then state=broken; else state=degraded; fi
    cls="$fault_class"; n="$faults"
else
    fails=0; state=ok; cls=none; n=0
fi
{ echo "fails=$fails"; echo "class=$cls"; cat "$TMP/rejected"; } > "$STATE_FILE"

EPOCH="$(date +%s)"
EMPTY="$(git -C "$MIRROR" hash-object -w --stdin </dev/null)"
NEW="$NS/$state/$cls/$n/$EPOCH"
{
    git -C "$MIRROR" for-each-ref --format='%(refname)' "$NS" "$NS_STUCK" 2>/dev/null \
        | while IFS= read -r old; do
            # a same-second re-publish keeps its name: update, never delete-and-create
            case "$old" in "$NEW"|"$NS_STUCK"/*/"$EPOCH") continue ;; esac
            printf 'delete %s\n' "$old"
        done
    printf 'update %s %s\n' "$NEW" "$EMPTY"
    awk '$3 >= 3 { print $2 }' "$TMP/rejected" | while IFS= read -r r; do
        h="$(printf '%s' "$r" | git hash-object --stdin)"
        printf 'update %s/%s/%s %s\n' "$NS_STUCK" "$h" "$EPOCH" "$EMPTY"
    done
} > "$TMP/tx"
git -C "$MIRROR" update-ref --stdin < "$TMP/tx" 2>"$TMP/err" || { echo "publish-relay-state: update-ref failed: $(cat "$TMP/err")" >&2; exit 1; }
echo "published:$NEW stuck=$(awk '$3 >= 3' "$TMP/rejected" | grep -c .)"
