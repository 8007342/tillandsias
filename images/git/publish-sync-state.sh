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
#   heads-current                every exported head is at or ahead of its
#                                tracking twin
#   heads-behind/<n>             <n> exported heads are behind theirs
#   heads-unknown/no-tracking-data
#                                the mirror has no tracking refs at all, so the
#                                question CANNOT be answered here
# `heads-behind` and `heads-unknown` are different answers and must never
# collapse into one. A mirror that has never fetched upstream is not a current
# mirror, and reporting it as current is the failure this row was filed about.
#
# EVERY STATE NAMES ITS SCOPE, and that is deliberate rather than verbose
# (coordinator's ruling, 2026-09-22). TAGS ARE OUT OF T1: the pre-push refspec
# is heads-only, so no upstream tag state exists to compare against — measured
# on lenovinha, where latest/stable/unstable survived a full container restart
# while upstream had moved. Publishing a tag verdict from data that does not
# exist would be worse than publishing none.
#
# So the scope lives IN THE VOCABULARY rather than in a comment nobody reads at
# the point of use. A bare `current` would be true and would invite exactly the
# wrong inference — a reader wants "is my mirror current" and would take it for
# an answer about everything the mirror holds. `heads-current` cannot be
# misread that way. This is the general lesson of 1345-8hyg turned into a
# naming rule: a verdict should name its SCOPE, not just its outcome, because
# the reader supplies the broader reading every time and being the author of
# the narrower meaning is no protection.
#
# Tags joining this state is its own row when a consumer needs it, and the
# justification will have to be a consumer that reads tags FROM THE MIRROR —
# today the things that need tags read GitHub. Growing the refspec also touches
# the rejection path relay-refs.sh's comment warns about, which deserves its own
# review rather than a ride inside T1.
#
# Usage: publish-sync-state <bare-mirror-dir> [<branch>]
# Emits zero or one note line, then exactly one verdict line, on stdout:
#   note:sync-state:diverged-work-refs:<n>   (information only; not the verdict)
#   sync-state:<state>:<epoch>               (always the LAST line)

MIRROR="${1:-}"
# Optional push target. Unset keeps the whole-mirror verdict the cadence
# callers (entrypoint, relay-refs) publish.
BRANCH="${2:-}"

log_msg() { echo "[publish-sync-state] $*" >&2; }

if [ -z "$MIRROR" ] || [ ! -d "$MIRROR" ]; then
    log_msg "usage: publish-sync-state <bare-mirror-dir>"
    echo "sync-state:heads-unknown:0"
    exit 2
fi

EPOCH="$(date -u +%s)"

# ── Count, per exported head, how far its tracking twin is ahead. ────────────
# An exported head with NO tracking twin is not "behind": it is a head upstream
# has never been asked about (a purely local salvage ref, say). Counting it as
# behind would make every mirror permanently behind and the verdict useless.
#
# THE VERDICT IS SCOPED TO THE PUSH TARGET when a branch is named (order
# 1350-ku7v, coordinator's ruling 2026-09-23). The question the verdict
# answers is "is it safe to spend a push on this mirror", and that depends
# only on the branch being pushed. Measured on lenovinha 2026-09-23: four
# work refs force-pushed upstream stayed diverged in the mirror (the reconcile
# fetch is non-forced by design, order 449), every one counted as behind, and
# --sync answered heads-behind with main and linux-next both current. Fleet
# work refs are rebased routinely, so an unscoped count can never answer
# current.
#
# A DIVERGED work/* HEAD IS INFORMATION, NOT VERDICT. With no branch named,
# it is left out of the behind count and reported on a note: line, so the
# force-push churn stays visible without pinning the answer. A diverged head
# that is NOT a work ref still counts: trunk and platform heads are not
# rewritten, so divergence there is a real hazard.
behind_heads=0
tracked_heads=0
tracking_total=0
diverged_work=0

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
    [ "$_n" -gt 0 ] || continue
    _ahead="$(git -C "$MIRROR" rev-list --count "${_track}..${_ref}" 2>/dev/null)" || _ahead=0
    [ -n "$_ahead" ] || _ahead=0
    _diverged_work=0
    case "$_short" in
        work/*) [ "$_ahead" -gt 0 ] && _diverged_work=1 ;;
    esac
    [ "$_diverged_work" -eq 1 ] && diverged_work=$((diverged_work + 1))
    if [ -n "$BRANCH" ]; then
        [ "$_short" = "$BRANCH" ] && behind_heads=$((behind_heads + 1))
    elif [ "$_diverged_work" -eq 0 ]; then
        behind_heads=$((behind_heads + 1))
    fi
done

# A named branch with no tracking twin cannot be answered: that is unknown,
# never current. The scope was the whole question.
if [ -n "$BRANCH" ] && ! git -C "$MIRROR" rev-parse --verify --quiet \
        "refs/remotes/origin/${BRANCH}" >/dev/null 2>&1; then
    tracking_total=0
fi

if [ "$tracking_total" -eq 0 ]; then
    STATE="heads-unknown"
    DETAIL="no-tracking-data"
elif [ "$behind_heads" -gt 0 ]; then
    STATE="heads-behind"
    DETAIL="$behind_heads"
else
    STATE="heads-current"
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

if [ "$diverged_work" -gt 0 ]; then
    echo "note:sync-state:diverged-work-refs:${diverged_work}"
fi
echo "sync-state:${STATE}:${EPOCH}"
