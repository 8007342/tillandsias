#!/bin/sh
# @trace spec:git-mirror-service
# reconcile-exported-heads <bare-mirror-dir>
#
# Order 449: one bounded-window reconcile pass for a single mirror. The
# mirror historically reconciled with upstream only on a push FAILURE, so a
# host coordinator pushing DIRECT to origin left the mirror's exported
# refs/heads/* stale between forge launches — an agent then cloned stale,
# committed on that base, and its push diverged (Hy3, live 2026-07-20).
#
# This pass advances the EXPORTED heads from upstream where fast-forwardable
# and repairs an unborn HEAD. Invariants shared with the startup sweep:
#   - NON-forced fetch (no leading '+'): a head carrying local un-relayed
#     agent commits is LEFT ALONE (fetch reports non-fast-forward) and is
#     relayed UP by the push path — agent work is never clobbered.
#   - Never --mirror/--all: explicit exported refs/heads/* refspec only
#     (sparse-mirror invariant).
#   - Fetch failures are non-fatal: an offline upstream keeps serving the
#     last-known-good heads.
#
# Exit 0 always (per-pass errors are reported on stdout/stderr and left for
# the next pass); the entrypoint's periodic loop and offline fixtures both
# run THIS file so there is exactly one implementation.

mirror="$1"
if [ -z "$mirror" ] || [ ! -d "$mirror" ]; then
    echo "reconcile-exported-heads: usage: reconcile-exported-heads <bare-mirror-dir>" >&2
    exit 2
fi

REMOTE="$(git -C "$mirror" remote get-url origin 2>/dev/null || true)"
if [ -z "$REMOTE" ]; then
    # Local-only mirror: nothing upstream to reconcile from.
    exit 0
fi

# BEGIN-1606-REFLOG
# ORDER 1606-25nf: the tracking twins (refs/remotes/origin/*) keep a reflog, so
# "upstream EVER held this commit" is answerable after a rewrite has moved the
# twin on. Bare repositories default logAllRefUpdates off. The expiry is set
# here, explicitly, so the bound on that history is visible in config: when it
# lapses (or the mirror is rebuilt) a rewrite degrades to DIVERGED, never to a
# clobber.
git -C "$mirror" config core.logAllRefUpdates always 2>/dev/null || true
git -C "$mirror" config 'gc.refs/remotes/origin/*.reflogExpire' 30.days 2>/dev/null || true
git -C "$mirror" config 'gc.refs/remotes/origin/*.reflogExpireUnreachable' 30.days 2>/dev/null || true
# END-1606-REFLOG

OUT="$(git -C "$mirror" fetch origin 'refs/heads/*:refs/heads/*' 2>&1)" || true
if [ -n "$OUT" ]; then
    echo "reconcile-exported-heads: $OUT"
fi

# BEGIN-1606-FOLLOW
# ORDER 1606-25nf — A WORK REF REWRITTEN UPSTREAM IS FOLLOWED, NOT LEFT STALE.
#
# The fetch above is non-forced (order 449), so an upstream rebase or amend of
# a work ref is refused and the exported head keeps a tip upstream abandoned.
# Measured 2026-10-11: work/1590-j20f served c42a22b29 to every forge while
# upstream (and the twin) held 337dc0df9, which had landed, and the published
# state read heads-current.
#
# A work/* head that has DIVERGED from its twin (each has commits the other
# lacks) is moved to the twin when every commit in `head ^twin` is reachable
# from the twin's current or any reflogged value: upstream once held all of
# it, so this is a rewrite, not un-relayed work, and nothing is lost. A head
# carrying a commit no upstream value ever held is left alone, as order 449
# requires, and reported `diverged`. A head that is only AHEAD of its twin is a
# relay in flight and is neither. The coordinator's ruling is on the row.
_compared=0 _followed=0 _diverged=0
for _ref in $(git -C "$mirror" for-each-ref --format='%(refname)' refs/heads/work/ 2>/dev/null); do
    _short="${_ref#refs/heads/}"
    _twin="refs/remotes/origin/${_short}"
    _t="$(git -C "$mirror" rev-parse --verify --quiet "$_twin" 2>/dev/null)" || continue
    _compared=$((_compared + 1))
    _h="$(git -C "$mirror" rev-parse --verify --quiet "$_ref" 2>/dev/null)" || continue
    [ "$_h" = "$_t" ] && continue
    git -C "$mirror" merge-base --is-ancestor "$_t" "$_h" 2>/dev/null && continue
    git -C "$mirror" merge-base --is-ancestor "$_h" "$_t" 2>/dev/null && continue
    # Every value the twin has held, current included (empty without a reflog).
    _hist="$(git -C "$mirror" reflog show --format=%H "$_twin" 2>/dev/null)" || _hist=""
    # Commits in the head that neither the twin nor any of its past values reach.
    # shellcheck disable=SC2086
    _unheld="$(git -C "$mirror" rev-list --max-count=1 "$_h" --not "$_t" $_hist 2>/dev/null)" || _unheld="x"
    if [ -z "$_unheld" ] && git -C "$mirror" update-ref -m "1606-25nf: follow upstream rewrite" "$_ref" "$_t" "$_h" 2>/dev/null; then
        _followed=$((_followed + 1))
        echo "sync:work-ref-followed-upstream:${_short}:${_h}..${_t}"
    else
        _diverged=$((_diverged + 1))
        # One reflog entry is the twin's current value only: no history to judge by.
        _n=0
        for _x in $_hist; do _n=$((_n + 1)); done
        if [ "$_n" -le 1 ]; then
            echo "diverged:${_short}:no-twin-history"
        else
            echo "diverged:${_short}:unrelayed-commits"
        fi
    fi
done
echo "sync:work-refs:compared=${_compared} followed=${_followed} diverged=${_diverged}"
# END-1606-FOLLOW

# New heads may have just arrived; HEAD must name a cloneable one.
ENSURE_HEAD="${ENSURE_HEAD:-/usr/local/share/git-service/ensure-mirror-head}"
if [ -x "$ENSURE_HEAD" ]; then
    "$ENSURE_HEAD" "$mirror" || true
fi
exit 0
