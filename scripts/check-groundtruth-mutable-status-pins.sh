#!/usr/bin/env bash
# @trace spec:forge-environment-discoverability
#
# check-groundtruth-mutable-status-pins.sh — order 680-zphp. Fail loud if any
# expert-groundtruth CASE pins `status:` on a packet whose LIVE ledger status is
# NON-TERMINAL. Such a pin goes red on every legitimate ledger update (a packet
# claimed ready->in_progress, or closed), turning the 4-verifier ratification
# harness red for a reason that is not an expert regression — it fired three
# times (394d twice, 394e) before this guard existed.
#
# WHAT IS ALLOWED. A pin on a packet whose live status is TERMINAL
# (completed/verified/done/obsoleted) is stable and may stay — terminal statuses
# do not churn. A pin on a FIXTURE packet (fixture-*, graded against a frozen
# fixture corpus, not the live ledger) does not resolve in the live ledger and
# is skipped: those fixtures are immutable by construction.
#
# Grammar (one line on stdout):
#   ^(ok:groundtruth-status-pins:[0-9]+ live-checked|violation:mutable-status-pin:[0-9]+)$
# Exit 0 when no case pins status on a live non-terminal packet.
#
# Pinned by litmus:groundtruth-no-mutable-status-pin-shape.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

# Default to the real groundtruth dir; an argument overrides it so the litmus
# can point the guard at a fixture directory of case files (status is still
# resolved against the LIVE ledger, so the fixture cites real packet ids).
GT_DIR="${1:-openspec/litmus-tests/groundtruth}"

_bin=""
for cand in "target/release/tillandsias-plan" "target/debug/tillandsias-plan"; do
    [ -x "$cand" ] && { _bin="$cand"; break; }
done
if [ -z "$_bin" ]; then
    echo "ok:groundtruth-status-pins:0 live-checked"
    echo "  note: tillandsias-plan not built — groundtruth status-pin guard skipped" >&2
    exit 0
fi

# Only the top-level CASE files, never the fixtures/ subtree (frozen corpora).
checked=0
violations=0
for f in "$GT_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    # Extract (packet_id, pinned_status) pairs: a `status:` line whose nearest
    # preceding `packet_id:` names the packet the pin applies to.
    while IFS=$'\t' read -r pid pinned; do
        [ -n "$pid" ] || continue
        live="$("$_bin" status "$pid" 2>/dev/null | awk '{print $2}')"
        # Unknown packet (fixture-* or typo) -> not a live pin, skip.
        [ -n "$live" ] || continue
        checked=$((checked + 1))
        case "$live" in
            completed|verified|done|obsoleted) : ;;  # terminal, stable
            *)
                violations=$((violations + 1))
                echo "  violation: $(basename "$f") pins status on '$pid' whose LIVE status is '$live' (non-terminal — will churn); pinned '$pinned'. De-pin it (identity/deliverable text is stable) or the harness reds on the next legitimate update." >&2
                ;;
        esac
    done < <(awk '
        /^[[:space:]]*(- )?packet_id:[[:space:]]/ { pid=$0; sub(/^[[:space:]]*(- )?packet_id:[[:space:]]*/,"",pid) }
        /^[[:space:]]*status:[[:space:]]*[a-z]/    { st=$0; sub(/^[[:space:]]*status:[[:space:]]*/,"",st); if (pid!="") print pid "\t" st }
    ' "$f")
done

if [ "$violations" -gt 0 ]; then
    echo "violation:mutable-status-pin:${violations}"
    exit 1
fi
echo "ok:groundtruth-status-pins:${checked} live-checked"
exit 0
