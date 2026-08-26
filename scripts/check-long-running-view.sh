#!/usr/bin/env bash
# @trace spec:meta-orchestration
# =============================================================================
# check-long-running-view.sh — order 251 criterion LM-04.
#
# `plan/long-running.md` is declared a FILTERED VIEW of the active
# `multi_cycle: true` packets (methodology/distributed-work.yaml ->
# long_running_packets.sub_queue_view). Nothing enforced that. It drifted in
# July 2026 (GPT verification found orders 315/330/334 absent), was repaired by
# hand, and drifted again — worse.
#
# MEASURED on yoga 2026-08-25: the ledger carries 31 `multi_cycle` packets, 27
# of them live. The view listed 11 rows, FOUR of which name obsoleted packets,
# and omitted 20 live ones. It was right about 7 of 31. A sub-queue that is 23%
# accurate is not a view, it is a decoy: an agent reading it to find claimable
# long-running work is steered toward dead packets and away from live ones.
#
# THE POINT IS THE RATCHET, NOT THIS REPAIR. Repairing by hand is what happened
# in July; it bought six weeks. This makes the invariant machine-checked so the
# next divergence fails a gate instead of waiting for a human verifier to
# notice — the same move 660-ryhn made for unbound litmus files and 801-qasc
# made for the daily-maintenance marker.
#
# WHY IT COMPARES SETS AND NOT RENDERING. The view carries prose columns
# (phase, blocked-on, outstanding verifications) that no generator can derive
# from the ledger alone — they are editorial. So this checks the one property
# that IS derivable and is the one that rotted: WHICH ORDERS APPEAR. Generating
# the whole file would either lose that editorial content or fabricate it.
#
# Verdict grammar, one line on stdout:
#   ok:long-running-view:<n> live packets listed          exit 0
#   violation:long-running-view:missing=<n>:stale=<n>     exit 1
#   blocked:<reason>                                      exit 2
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

VIEW="${TILLANDSIAS_LONG_RUNNING_VIEW:-plan/long-running.md}"
INDEX="${TILLANDSIAS_LONG_RUNNING_INDEX:-plan/index.yaml}"

[ -r "$INDEX" ] || { echo "blocked:index-unreadable:$INDEX"; exit 2; }
[ -r "$VIEW" ]  || { echo "blocked:view-unreadable:$VIEW"; exit 2; }

# Terminal statuses. A packet in one of these is DONE with the queue and must
# not appear in an "active" view; everything else is live.
TERMINAL_RE='^(done|obsoleted|superseded|completed|failed|cancelled)$'

# Walk the packet list once, carrying (order, status, multi_cycle) per packet
# and emitting at the boundary. Deliberately a single awk pass over the folded
# base rather than a grep -B window: a -B window silently mis-attributes when a
# packet's field order differs, and this file is hand-edited by many hosts.
live_orders() {
    awk -v term="$TERMINAL_RE" '
        function flush() {
            if (mc == 1 && ord != "" && status !~ term) print ord
            ord = ""; status = ""; mc = 0
        }
        /^    - packet_id: / { flush(); next }
        /^      order: /      { if (ord == "") { ord = $2; gsub(/["'\'']/, "", ord) } ; next }
        /^      status: /     { if (status == "") { status = $2; gsub(/["'\'']/, "", status) } ; next }
        /^      multi_cycle: true/ { mc = 1; next }
        END { flush() }
    ' "$INDEX" | sort -u
}

# Orders the view claims, read from the leading cell of each table row. Anchored
# to the row shape so prose mentioning an order elsewhere in the file is not
# mistaken for a listing.
view_orders() {
    sed -n 's/^| *\([0-9][0-9a-z-]*\) *|.*/\1/p' "$VIEW" | sort -u
}

live="$(live_orders)"
listed="$(view_orders)"

if [ -z "$live" ]; then
    echo "blocked:no-multi-cycle-packets-parsed"
    exit 2
fi

missing="$(comm -23 <(printf '%s\n' "$live") <(printf '%s\n' "$listed"))"
stale="$(comm -13 <(printf '%s\n' "$live") <(printf '%s\n' "$listed"))"

n_missing=$(printf '%s' "$missing" | grep -c . || true)
n_stale=$(printf '%s' "$stale" | grep -c . || true)
n_live=$(printf '%s\n' "$live" | grep -c . || true)

if [ "$n_missing" -ne 0 ] || [ "$n_stale" -ne 0 ]; then
    [ "$n_missing" -ne 0 ] && {
        echo "  LIVE multi_cycle packets absent from $VIEW:" >&2
        printf '%s\n' "$missing" | sed 's/^/    missing: /' >&2
    }
    [ "$n_stale" -ne 0 ] && {
        echo "  Rows in $VIEW naming no live multi_cycle packet (terminal or gone):" >&2
        printf '%s\n' "$stale" | sed 's/^/    stale:   /' >&2
    }
    echo "  $VIEW is declared a filtered view of ACTIVE multi_cycle packets" >&2
    echo "  (methodology/distributed-work.yaml -> long_running_packets.sub_queue_view)." >&2
    echo "  Add a row for each missing order and remove each stale one, in the same" >&2
    echo "  commit as the change that moved it. The prose columns are editorial and" >&2
    echo "  cannot be generated — that is why this checks membership, not rendering." >&2
    echo "violation:long-running-view:missing=${n_missing}:stale=${n_stale}"
    exit 1
fi

echo "ok:long-running-view:${n_live} live packets listed"
exit 0
