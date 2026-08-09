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

PLAN=""
for c in ./target/release/tillandsias-plan ./target/debug/tillandsias-plan "$(command -v tillandsias-plan 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { PLAN="$c"; break; }
done
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
        case "$want" in
            completed|done|retired|obsolete|blocked|failed)
                violations="${violations}${pid}: declared '${want}' in a fragment, folds as '${got}'"$'\n'
                ;;
        esac
    fi
done <<< "$declared"

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
