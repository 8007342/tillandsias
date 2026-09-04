#!/usr/bin/env bash
# dispatch-brief.sh — emit the facts a dispatch must carry, so a coordinator
# cannot brief a host from memory or from a packet's filing-time prose.
#
# ORDER 980-krib, criterion 3. The coordinator kept briefing hosts on work that
# was already done. Three measured instances on 2026-09-02/03: a forge was sent
# four rungs of 920-pxg6 that had landed days earlier and spent its cycle
# proving the brief stale; yoga was dispatched to 976-kk6x an hour after closing
# that cycle; lenovinha was told 969-nhh7 was "still ready and unclaimed", which
# was true and misleading, because another host had landed it and released.
#
# The criterion says the brief must CARRY THE HEAD IT WAS WRITTEN AGAINST so the
# host can detect staleness itself. That is a discipline, and a discipline that
# depends on the coordinator remembering is one the coordinator forgets — which
# is the lesson of the landing tool (859-4jny) and of salvage. So it is a
# command, and its output is meant to be pasted into the dispatch.
#
# usage: scripts/dispatch-brief.sh <order|packet_id> [more...]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ $# -ge 1 ] || { echo "usage: dispatch-brief.sh <order|packet_id> [more...]" >&2; exit 2; }

# The shared probe, not a hardcoded target/ path (721-nyev, 751-vega): an
# executable bit is a claim, RUNNING the binary is evidence. The gate caught my
# first version doing exactly what it forbids — the same violation lenovinha hit
# in the 972-6vaj fixture hours earlier, so this is the second instance today
# and the guard found both.
# shellcheck source=scripts/plan-binary-probe.sh
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
PLAN="$(resolve_plan_binary)" || {
    echo "refused:dispatch-brief:no-runnable-plan-binary — run scripts/cycle-preflight.sh" >&2
    exit 2
}

head="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
remote="$(git -C "$ROOT" rev-parse --short '@{u}' 2>/dev/null || echo unknown)"
printf 'BRIEF WRITTEN AGAINST: local %s / upstream %s / %s\n' \
    "$head" "$remote" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$head" != "$remote" ]; then
    printf '  WARNING: local and upstream differ — this brief may already be stale.\n'
fi

rc=0
for want in "$@"; do
    printf '\n=== %s ===\n' "$want"
    line="$("$PLAN" status "$want" 2>/dev/null)" || { printf '  refused: no packet matches\n'; rc=1; continue; }
    printf '  %s\n' "$line"

    events="$("$PLAN" plan-events "$want" 2>/dev/null)"
    if [ -z "$events" ]; then
        printf '  UNTOUCHED — no events. Brief from the packet as filed.\n'
    else
        n="$(printf '%s\n' "$events" | wc -l | tr -d ' ')"
        printf '  WORKED — %s event(s). DO NOT brief from the context: block; it is the\n' "$n"
        printf '  filing-time defect list and reads as current state months later.\n'
        printf '  Last 3:\n'
        printf '%s\n' "$events" | tail -3 | sed 's/^/    /'
    fi
done
exit "$rc"
