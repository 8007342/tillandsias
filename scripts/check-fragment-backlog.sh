#!/usr/bin/env bash
# check-fragment-backlog.sh — compaction-cadence advisory (941-trcf A1).
# @trace spec:methodology-accountability
#
# WHY THIS EXISTS, with the numbers that earned it. Every heavy
# tillandsias-plan invocation overlays plan/index.d/ onto the base ledger,
# and that overlay cost is LINEAR IN THE BACKLOG: measured 2026-08-30 on
# macuahuitl, 338 accumulated fragments put ~160ms of overlay into every
# ~258ms heavy load, and one full ./build.sh --check performs ~88 such
# loads — compacting the backlog halved the warm gate (118s -> 56s).
# Per-fragment, that is roughly 40ms of gate time per gate run, silently,
# on every host, with Windows paying its 9P multiplier on top.
#
# The threshold is 50: ~2s of gate cost, far below noise, but early enough
# that whoever sees the line can fold before the backlog is 338 again.
#
# ADVISORY, NOT A GATE (the 751-i9mb terms): a grown backlog is news for
# the next coordination cycle, not a build break — redding the gate over
# fragment count would train exactly the compact-in-a-hurry-mid-story
# behaviour the CRDT lane exists to avoid. Compaction belongs to a cycle
# that can gate, commit and push the fold as one unit.
#
# Exit is 0 unless the CHECK ITSELF cannot run (missing directory is a
# fine, empty backlog — a fully compacted tree is the goal state, not an
# error; see the empty-index.d defects this same packet flushed out).
set -uo pipefail

FRAG_DIR="plan/index.d"
THRESHOLD="${TILLANDSIAS_FRAGMENT_BACKLOG_THRESHOLD:-50}"

count=0
if [ -d "$FRAG_DIR" ]; then
    for _f in "$FRAG_DIR"/*.yaml; do
        [ -e "$_f" ] && count=$((count + 1))
    done
fi

if [ "$count" -gt "$THRESHOLD" ]; then
    echo "advisory:fragment-backlog:${count}>${THRESHOLD} — every heavy plan load re-overlays all ${count} fragments (~0.5ms each, ~88 loads per gate); run 'tillandsias-plan compact' in a cycle that can gate+commit+push the fold (941-trcf)"
else
    echo "ok:fragment-backlog:${count}<=${THRESHOLD}"
fi
exit 0
