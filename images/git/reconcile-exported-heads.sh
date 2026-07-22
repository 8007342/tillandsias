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

OUT="$(git -C "$mirror" fetch origin 'refs/heads/*:refs/heads/*' 2>&1)" || true
if [ -n "$OUT" ]; then
    echo "reconcile-exported-heads: $OUT"
fi

# New heads may have just arrived; HEAD must name a cloneable one.
ENSURE_HEAD="${ENSURE_HEAD:-/usr/local/share/git-service/ensure-mirror-head}"
if [ -x "$ENSURE_HEAD" ]; then
    "$ENSURE_HEAD" "$mirror" || true
fi
exit 0
