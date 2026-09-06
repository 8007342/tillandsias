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


# ORDER 943-26rx. APPLY THE FRAGMENT LWW STATUS OVERLAY BEFORE JUDGING.
#
# The awk pass above reads only the FOLDED BASE. That was a real blind spot,
# not a theoretical one: `tillandsias-plan set-field <id> status done` — the
# closure method the worker protocol MANDATES (never hand-author a status) —
# writes to a `plan/index.d/` fragment, and the base keeps the old status until
# the next fold. Measured 2026-08-30: 321 unfolded fragments spanning four
# days, 144 of them carrying a `field: status` entry.
#
# Both directions of the resulting failure are bad, and one was LIVE when this
# was written:
#   * a packet closed by set-field still reads `live` here, so this gate
#     DEMANDS it stay in the active view — and refuses the push of whoever
#     correctly removes the row. The trunk reds for doing the right thing.
#   * left in, the view advertises a closed packet as claimable long-running
#     work. That is exactly the DECOY failure this gate was built to end
#     (2026-08-25: four obsoleted packets listed, twenty live ones absent),
#     recurring through the gate itself.
# Live instance at the time of the fix: order 831-ezea, `completed` per the
# folding reader, `live` per the base, and duly listed in the view.
#
# The plan binary is the sanctioned folding reader, so ask it. It is a
# REFINEMENT, never a widener: it can only move an order from live to
# terminal, so a host without a usable binary degrades to the old base-only
# answer rather than failing the build. That asymmetry is deliberate — a gate
# that goes RED when its optional reader is missing gets switched off.
apply_fragment_status_overlay() {
    local plan_bin status_map classified cls o s kept=""
    # shellcheck source=/dev/null
    . "$REPO_ROOT/scripts/plan-binary-probe.sh" 2>/dev/null || { cat; return 0; }
    plan_bin="$(resolve_plan_binary)" || { cat; return 0; }

    # ── THE FOLD, READ ONCE, BUT ARCHIVE-AWARE (order 964-tzmp) ──────────────
    #
    # This loop used to spawn `status` PER PACKET, each re-folding the whole
    # ledger: 27 calls at ~0.20s = 5.4s, the entire cost of this gate step.
    # MEASURED 2026-09-02 by wrapping the binary through TILLANDSIAS_PLAN_BIN
    # and logging every invocation of one forced `./build.sh --check`.
    #
    # `query --json` is the same folded reader (582-26mm), so one call replaces
    # N. But it returns the LIVE FOLD ONLY, while `status` ALSO resolves
    # ARCHIVED rows — and that difference is the whole point of this overlay.
    # Order 831-ezea reads `completed ARCHIVED` via status and is ABSENT from
    # query, so a map-only join treats it as unknown and KEEPS it, making this
    # gate demand that a closed, archived packet stay in the active view. That
    # is precisely the 943-26rx defect the overlay was added to fix, and
    # precisely what litmus:long-running-view-agreement step 6 pins.
    #
    # The first version of this batching omitted the fallback and turned that
    # step RED on the trunk, while `./build.sh --check` stayed GREEN: the gate
    # runs no litmus (748-tkjx) and 0 of the 28 orders currently in the view are
    # archived, so the live tree could not expose it — only the fixture could.
    # check-fragment-status-loss.sh, the file this batching was copied FROM,
    # already carried an archived-row re-ask for exactly this reason. The reader
    # was copied; the knowledge was not.
    #
    # So the map answers the common case with no subprocess, and ONLY orders
    # absent from it pay a per-packet archive-aware resolve. Today: zero calls.
    #
    # FAIL-SAFE: if the batch cannot be built — a binary predating `query`, a
    # jq-less host, a harness binary advertising a subcommand it does not
    # implement — fall back to exactly the per-packet calls this replaced.
    # Slower is acceptable; judging NOTHING is not, because an empty map would
    # silently keep every row, which is the decoy failure this gate exists to
    # end.
    #
    # bash-dialect: 3.2-clean on purpose (761-g36m). An earlier draft used
    # `declare -A`, which is bash-4-only and would have broken the macOS host
    # this script also runs on; the dialect gate caught it before it landed.
    status_map=""
    if plan_binary_has "$plan_bin" query && command -v jq >/dev/null 2>&1; then
        status_map="$("$plan_bin" query --json --limit 0 2>/dev/null \
            | jq -r '.[] | select((.packet_id // "") != "" or (.order // "") != "") | [((.order // .packet_id)|tostring), (.status // "")] | @tsv' 2>/dev/null | tr -d '')"
    fi

    if [ -n "$status_map" ]; then
        # One awk pass joins the map against the orders on stdin and classifies
        # each: KEEP (live per the map), dropped (terminal per the map), or MISS
        # (absent from the live fold — may be archived, so it must be re-asked).
        #
        # THE MAP TRAVELS AS A FILE, NOT AS `-v map=…` (order 935-6fzk cycle).
        # A `-v` assignment is a STRING LITERAL: gawk tolerates embedded
        # newlines in one, BSD awk — every macOS host — rejects it outright with
        # `awk: newline in string`. The pass then produced NOTHING, every row
        # classified as neither KEEP nor MISS, and the gate reported `stale=28`
        # of 28 on a tree where linux-next reported `ok:…28 live packets
        # listed`. That is this function's own decoy failure, arriving through
        # the parser instead of through an empty query. `-v` also expands
        # backslash escapes, so it is the wrong channel for data on EVERY
        # platform, not only BSD.
        local map_file
        map_file="$(mktemp "${TMPDIR:-/tmp}/long-running-map.XXXXXX")" || { cat; return 0; }
        printf '%s\n' "$status_map" > "$map_file"
        classified="$(awk -F'\t' '
            NR == FNR { if (NF == 2) st[$1] = $2; next }
            { order = $1
              if (order == "") next
              if (order in st) {
                  s = st[order]
                  if (s == "done" || s == "obsoleted" || s == "superseded" \
                      || s == "completed" || s == "failed" || s == "cancelled") next
                  print "KEEP\t" order
              } else {
                  print "MISS\t" order
              } }' "$map_file" -)"
        rm -f "$map_file"
        printf '%s\n' "$classified" | while IFS="$(printf '\t')" read -r cls o; do
            [ -n "$o" ] || continue
            if [ "$cls" = "KEEP" ]; then
                printf '%s\n' "$o"
            else
                s="$("$plan_bin" status "$o" 2>/dev/null | awk 'NR==1{print $2}')"
                case "$s" in
                    done|obsoleted|superseded|completed|failed|cancelled) ;;
                    *) printf '%s\n' "$o" ;;
                esac
            fi
        done
        return 0
    fi

    while read -r o; do
        [ -n "$o" ] || continue
        s="$("$plan_bin" status "$o" 2>/dev/null | awk 'NR==1{print $2}')"
        case "$s" in
            done|obsoleted|superseded|completed|failed|cancelled) continue ;;
            *) kept="$kept$o"$'\n' ;;
        esac
    done
    printf '%s' "$kept"
}

# Orders the view claims, read from the leading cell of each table row. Anchored
# to the row shape so prose mentioning an order elsewhere in the file is not
# mistaken for a listing.
view_orders() {
    sed -n 's/^| *\([0-9][0-9a-z-]*\) *|.*/\1/p' "$VIEW" | sort -u
}

# ORDER 943-26rx: the emptiness guard now asks the BASE PARSE, not the final
# set. It exists to catch a broken awk pass ("the parser produced nothing"),
# and once the overlay was added those became two different conditions: a tree
# where every multi_cycle packet has been CLOSED legitimately has zero live
# orders, and reporting that as `blocked:no-multi-cycle-packets-parsed` blames
# the instrument for a true answer. Checked before the overlay, so a real parse
# failure is still caught, and an empty result AFTER refinement is reported as
# the ok:0 it is.
base_live="$(live_orders)"

if [ -z "$base_live" ]; then
    echo "blocked:no-multi-cycle-packets-parsed"
    exit 2
fi

live="$(printf '%s\n' "$base_live" | apply_fragment_status_overlay)"
listed="$(view_orders)"


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
