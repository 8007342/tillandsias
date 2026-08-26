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

# Resolve the case dir BEFORE the cd, so a caller may pass a relative path to a
# fixture directory outside the repo. Previously the cd below silently
# reinterpreted any relative argument against the repo root.
GT_DIR="${1:-openspec/litmus-tests/groundtruth}"
case "$GT_DIR" in
    /*) : ;;
    *) [ -d "$GT_DIR" ] && GT_DIR="$(cd "$GT_DIR" && pwd)" ;;
esac

# THE LEDGER STATUS IS RESOLVED HERE, AND IT DID NOT USED TO BE OVERRIDABLE.
#
# ORDER 865-x2mf. This guard exists (680-zphp) to stop a groundtruth case
# pinning `status:` on a packet whose live status can still move. Its own
# negative control did exactly that: it pinned `status: ready` on packet 394 and
# required a refusal. 394 was later obsoleted — terminal — so the pin became
# legitimate, the guard correctly admitted it, and
# litmus:groundtruth-no-mutable-status-pin-shape went red looking for a refusal
# it could no longer earn. The litmus header still asserts "394 is ready
# (non-terminal, a trap)".
#
# The guard written to enforce "never depend on a live packet's status" had a
# test that depended on a live packet's status, and it broke exactly as the rule
# predicts. That is not a reason to pick a longer-lived packet — every live
# packet is mortal. It is a reason to let the TEST supply its own ledger.
#
# Defaults to the repo, so production behaviour is byte-identical.
LEDGER_ROOT="${TILLANDSIAS_GROUNDTRUTH_LEDGER_ROOT:-$REPO_ROOT}"
case "$LEDGER_ROOT" in
    /*) : ;;
    *) LEDGER_ROOT="$(cd "$LEDGER_ROOT" 2>/dev/null && pwd)" || LEDGER_ROOT="$REPO_ROOT" ;;
esac

cd "$REPO_ROOT" || exit 2

# Order 721-nyev: resolve by execution, not by the executable bit.
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
_bin="$(resolve_plan_binary || true)"
# ABSOLUTISE IT. resolve_plan_binary returns a REPO-RELATIVE path
# (`./target/release/tillandsias-plan`), and the status lookup below runs inside
# `cd "$LEDGER_ROOT"` — so a relative path silently resolves to nothing there,
# every lookup returns empty, every pin is skipped as "unknown packet", and the
# guard reports `0 live-checked` while looking exactly like a pass. I wrote a
# comment asserting this path was already absolute and did not check; it is not.
case "$_bin" in
    ''|/*) : ;;
    *) _bin="$REPO_ROOT/${_bin#./}" ;;
esac
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
        # Resolved from LEDGER_ROOT, which is the repo unless a test supplies
        # its own frozen ledger (865-x2mf). `_bin` is absolutised above, so the
        # subshell cd cannot lose it.
        live="$( cd "$LEDGER_ROOT" && "$_bin" status "$pid" 2>/dev/null | awk '{print $2}' )"
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
