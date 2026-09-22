#!/bin/sh
# @trace spec:git-mirror-service
# publish-sync-state <bare-mirror-dir>
#
# ORDER 1350-ku7v (T1 of openspec/changes/cloud-only-project-lifecycle).
#
# THE QUESTION THIS ANSWERS, and who is asking it. A forge reads its mirror and
# cannot reach GitHub. A bare-metal host pushes through its mirror and learns
# the mirror was stale only when a push has already been refused. Neither can
# currently ask "is this mirror current with upstream?" before spending
# something on the answer — a certificate mint, a push, or in the forge's case
# an unbounded confusion between a sha that HAS landed upstream and one that
# does not exist at all (1338-tkfh: those two produce an identical fatal).
#
# WHY THIS NEEDS NO NEW PROBE, MEASURED BEFORE IT WAS WRITTEN. relay-refs.sh's
# pre-push staleness guard already fetches upstream into the TRACKING namespace
# (`+refs/heads/*:refs/remotes/origin/*`) before every relay, deliberately not
# into the exported refs. So the mirror already holds, for every exported head,
# the upstream head it was last compared against. The distance is a rev-list.
# This script publishes what the mirror already knows; it does not go and look.
#
# THE SHAPE IS COPIED FROM probe-upstream-auth.sh ON PURPOSE, not invented:
#
#   refs/tillandsias/sync-state/<state>[/<detail>]/<epoch>
#
# and that shape carries three properties this question needs, each of which
# was load-bearing in the original and would have had to be rediscovered:
#
#   1. READABLE WITHOUT A CLONE. A forge learns the answer from
#      `git ls-remote <mirror> 'refs/tillandsias/*'` — no fetch, no object
#      transfer, no credential. Measured from a live forge on lenovinha
#      2026-09-22 before this file existed. The ref target is the EMPTY BLOB:
#      the PATH carries the whole message, so nothing has to be fetched to read
#      it. A state encoded in a commit would force the fetch a forge cannot
#      afford.
#   2. THE EPOCH BOUNDS STALENESS. "behind by 0" computed a second ago and an
#      hour ago are different facts and a consumer cannot tell them apart
#      without the timestamp. probe-upstream-auth's header puts it better:
#      yesterday's verdict is from yesterday's epoch.
#   3. A MIDDLE <detail> SEGMENT IS INVISIBLE TO A SIMPLE READER, because the
#      established consumer parse is `state="${rest%%/*}"` and
#      `epoch="${rest##*/}"` (order 809-w2xy). So detail can be added here
#      without breaking a reader that only wants the state.
#
# STATES, and the distinction that 1338-tkfh exists for:
#   current                      every exported head is at or ahead of its
#                                tracking twin
#   behind/<n>                   <n> exported heads are behind theirs
#   unknown/no-tracking-data     the mirror has no tracking refs at all, so the
#                                question CANNOT be answered here
# `behind` and `unknown` are different answers and must never collapse into
# one. A mirror that has never fetched upstream is not a current mirror, and
# reporting it as current is the failure this row was filed about.
#
# TAGS ARE OUT OF SCOPE AND SAY SO. The pre-push refspec is heads-only, so no
# upstream tag state exists to compare against — measured on lenovinha, where
# latest/stable/unstable survived a full container restart while upstream had
# moved. Publishing a tag verdict from data that does not exist would be worse
# than publishing none. Growing that refspec is a separate decision because it
# touches the rejection path relay-refs.sh's comment warns about.
#
# Emits exactly one line on stdout:  sync-state:<state>:<epoch>

MIRROR="${1:-}"

log_msg() { echo "[publish-sync-state] $*" >&2; }

if [ -z "$MIRROR" ] || [ ! -d "$MIRROR" ]; then
    log_msg "usage: publish-sync-state <bare-mirror-dir>"
    echo "sync-state:unknown:0"
    exit 2
fi

EPOCH="$(date -u +%s)"

# ── Count, per exported head, how far its tracking twin is ahead. ────────────
# An exported head with NO tracking twin is not "behind": it is a head upstream
# has never been asked about (a purely local salvage ref, say). Counting it as
# behind would make every mirror permanently behind and the verdict useless.
behind_heads=0
tracked_heads=0
tracking_total=0

for _tr in $(git -C "$MIRROR" for-each-ref --format='%(refname)' refs/remotes/origin 2>/dev/null); do
    tracking_total=$((tracking_total + 1))
done

for _ref in $(git -C "$MIRROR" for-each-ref --format='%(refname)' refs/heads 2>/dev/null); do
    _short="${_ref#refs/heads/}"
    _track="refs/remotes/origin/${_short}"
    git -C "$MIRROR" rev-parse --verify --quiet "$_track" >/dev/null 2>&1 || continue
    tracked_heads=$((tracked_heads + 1))
    _n="$(git -C "$MIRROR" rev-list --count "${_ref}..${_track}" 2>/dev/null)" || _n=0
    [ -n "$_n" ] || _n=0
    if [ "$_n" -gt 0 ]; then
        behind_heads=$((behind_heads + 1))
    fi
done

if [ "$tracking_total" -eq 0 ]; then
    STATE="unknown"
    DETAIL="no-tracking-data"
elif [ "$behind_heads" -gt 0 ]; then
    STATE="behind"
    DETAIL="$behind_heads"
else
    STATE="current"
    DETAIL=""
fi

# ── Publish, then prune older verdicts in this namespace. ────────────────────
# Publish-then-prune rather than prune-then-publish, so a reader racing this
# script sees the old verdict or the new one, never neither. The consumer's
# documented rule (largest epoch wins) covers the window in which both exist.
if [ -n "$DETAIL" ]; then
    NEW_REF="refs/tillandsias/sync-state/${STATE}/${DETAIL}/${EPOCH}"
else
    NEW_REF="refs/tillandsias/sync-state/${STATE}/${EPOCH}"
fi

if _blob="$(git -C "$MIRROR" hash-object -w --stdin </dev/null 2>/dev/null)" \
   && git -C "$MIRROR" update-ref "$NEW_REF" "$_blob" 2>/dev/null; then
    for _old in $(git -C "$MIRROR" for-each-ref --format='%(refname)' refs/tillandsias/sync-state 2>/dev/null); do
        [ "$_old" = "$NEW_REF" ] && continue
        git -C "$MIRROR" update-ref -d "$_old" 2>/dev/null || true
    done
else
    # Loud, and it does NOT change the verdict. A consumer treats an absent or
    # stale sync-state the same way it treats an absent upstream-auth verdict:
    # as not-current, which fails closed.
    log_msg "WARNING: could not publish $NEW_REF in $MIRROR"
fi

echo "sync-state:${STATE}:${EPOCH}"
