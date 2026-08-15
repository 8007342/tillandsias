#!/usr/bin/env bash
# @trace spec:ci-release
#
# check-fragment-status-loss.sh — catch status transitions that the fold silently
# discards.
#
# Order 635-i6vm.
#
# THE TRAP. `packets:` in a ledger fragment is a G-SET keyed by packet_id: the
# union of declarations, where re-adding an existing packet is a NO-OP. Status is
# a separate LWW-Register with its own `status:` channel keyed by (ts, host).
# Both facts are documented in plan/index.d/README.md and in fragments.rs.
#
# The failure mode is that re-declaring a packet with a new status LOOKS exactly
# like recording a transition. It parses, it validates, `tillandsias-plan check`
# passes, the diff reads correctly in review — and the fold throws the status
# away. Nothing anywhere says so.
#
# Measured 2026-08-09: 11 of 21 packets recorded `completed` in a fragment were
# still folding as `ready`. 52% of fragment-recorded completions had been
# silently discarded, some for two days. Two of them were handed to this host as
# "next work" by the batch selector in the cycle that found this — completed work
# being re-offered for implementation, which is the mechanical root of agents
# "going in circles" on work that is already done.
#
# This is NOT a heuristic or a ranking problem. It is a data-integrity defect
# that every downstream reader inherits, because every reader asks the fold.
#
# GRAMMAR — exactly one line:
#   ^(ok:no-fragment-status-loss:[0-9]+ checked|violation:fragment-status-loss:[0-9]+)$
# Exit 0 when no declared status is being discarded.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

FRAG_DIR="plan/index.d"
[ -d "$FRAG_DIR" ] || { echo "ok:no-fragment-status-loss:0 checked"; exit 0; }

# One probe, shared with every script that needs the binary (704-zcgi), and it
# resolves by EXECUTION (721-nyev): an executable BIT is a claim; RUNNING the
# binary is evidence. On a shared Windows/WSL checkout a WSL build leaves a
# Linux ELF at target/release/tillandsias-plan beside the runnable .exe, and a
# first-match-on--x loop selected the ELF. Falls back release, debug, then PATH.
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
PLAN="$(resolve_plan_binary)" || PLAN=""
[ -n "$PLAN" ] || { echo "violation:fragment-status-loss:0"; echo "  tillandsias-plan not built; cannot resolve the fold" >&2; exit 2; }

# Every (packet_id, status) pair declared under a `packets:` list in any
# fragment. Deliberately ignores the `status:` LWW channel — that one works.
declared="$(awk '
    /^  - packet_id:/ { pid = $3; st = ""; next }
    /^    status:/    { if (pid != "" && st == "") { st = $2; print pid "\t" st; pid = "" } }
' "$FRAG_DIR"/*.yaml 2>/dev/null | sort -u)"

[ -n "$declared" ] || { echo "ok:no-fragment-status-loss:0 checked"; exit 0; }

checked=0
violations=""
while IFS=$'\t' read -r pid want; do
    [ -n "$pid" ] || continue
    checked=$((checked + 1))
    got="$("$PLAN" status "$pid" 2>/dev/null | awk '{print $2}')"
    [ -n "$got" ] || continue
    if [ "$got" != "$want" ]; then
        # A packet legitimately declared `ready` in one fragment and later moved
        # on via the LWW channel is NOT a loss — the fold is ahead of the
        # declaration, which is correct. Only flag a declaration the fold is
        # BEHIND: a terminal status that never took effect.
        # Exactly the resolver's terminal set (is_terminal_status, 650-dq6u) —
        # a guard laxer OR wider than the resolver is decorative (649-b2e4).
        case "$want" in
            completed|verified|done|obsoleted)
                violations="${violations}${pid}: declared '${want}' in a fragment, folds as '${got}'"$'\n'
                ;;
        esac
    fi
done <<< "$declared"

# SECOND CLASS: a terminal EVENT with no matching status transition.
#
# The first pass above catches "declared terminal under `packets:`, discarded by
# the G-Set". It cannot see the other way a completion goes missing: recording
# `type: completed` as an EVENT and never writing the `status:` LWW entry.
# Nothing is discarded there, so nothing looks wrong — the packet simply stays
# claimable forever.
#
# Observed on three hosts. The macOS close-out on 2026-08-09 reported 624-q4jj
# ALL-PASS with a full evidence file, wrote `type: completed`, carried no
# `status:` block, and the packet was still being offered as work. Windows filed
# the naming half of the same trap as 642-fedr the same day. Three hosts
# independently is a write-path defect, not three mistakes.
event_violations=""
# Which packet_ids DECLARE a terminal `completed` event in their events block?
#
# ORDER 752-pst5. This used to be a line-grep with ad-hoc resets, and a grep
# cannot tell an event declaration from PROSE that quotes the marker inside a
# block scalar: packet 751-i9mb's own description quoted `type: completed` and
# the gate invented a completion for it. Attribution is now STRUCTURAL — the
# fragment is parsed as YAML and only `type:` keys under an events list count —
# via `fragment-terminal-events`, the same binary this script already requires
# for the fold. The per-file loop keeps the 598-kibt file-boundary isolation
# by construction: each fragment is read alone, so the last packet of one file
# can never inherit the first closure marker of the next.
if plan_binary_has "$PLAN" fragment-terminal-events; then
    declared_events="$(for f in "$FRAG_DIR"/*.yaml; do
        [ -f "$f" ] || continue
        "$PLAN" fragment-terminal-events "$f" 2>/dev/null
    done | sort -u)"
else
    # ORDER 702-68zj: a binary that predates the rule is STALE HOST STATE, not
    # a ledger defect. The first pass above still runs (it only needs `status`);
    # the event pass is skipped LOUDLY rather than approximated with an awk that
    # could again invent completions — a checker that invents completions is
    # worse than no checker, and a half-correct scanner is exactly the next
    # 752. Rebuild to enable the pass.
    declared_events=""
    echo "  note: $PLAN predates fragment-terminal-events — closure-event pass SKIPPED (rebuild with 'cargo build --release -p tillandsias-plan')" >&2
fi

if [ -n "$declared_events" ]; then
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        got="$("$PLAN" status "$pid" 2>/dev/null | awk '{print $2}')"
        [ -n "$got" ] || continue
        # A completed EVENT legitimately pairs with ANY closure-ladder terminal:
        # per 650-dq6u the event may set status to completed, or directly to
        # verified/done when the evidence meets that higher rung's bar.
        # obsoleted is accepted too (supersession recorded over a completion).
        case "$got" in
            completed|verified|done|obsoleted) ;;
            *)
                event_violations="${event_violations}${pid}: has a 'completed' EVENT but folds as '${got}'"$'\n'
                ;;
        esac
    done <<< "$declared_events"
fi

if [ -n "$event_violations" ]; then
    violations="${violations}${event_violations}"
fi

if [ -n "$violations" ]; then
    n="$(printf '%s' "$violations" | grep -c .)"
    echo "violation:fragment-status-loss:${n}"
    printf '%s' "$violations" | sed 's/^/  /'
    echo "  CAUSE: \`packets:\` is a G-Set — re-declaring a packet does NOT change its status."
    echo "  REMEDY: write a NEW fragment with a \`status:\` entry (packet_id/field/value/ts/host)."
    echo "          See plan/index.d/README.md."
    exit 1
fi

echo "ok:no-fragment-status-loss:${checked} checked"
