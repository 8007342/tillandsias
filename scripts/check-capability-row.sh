#!/usr/bin/env bash
# @trace order:850-bif2, spec:accel-capability-probe
#
# check-capability-row.sh — is THIS host visible in the capability matrix?
#
# WHY (order 850-bif2). Five of seven known hosts were silent in the matrix —
# not failed, simply never asked to publish — and capability-aware routing
# (847-wgy4) cannot route to hardware the matrix cannot see. This makes the
# question falsifiable so the meta-orchestration Start-Of-Day gate can act on
# it: a joining host's first cycle answers `due:` and publishes, every later
# cycle answers `ok:` for free.
#
# Grammar (exactly one line):
#   ^(ok:capability-row-reported:[a-z0-9-]+|due:no-capability-row:[a-z0-9-]+|unavailable:[a-z-]+)$
#
# Exit codes: 0 = row present; 1 = due (publish one via
# scripts/host-capability-probe.sh --fragment); 2 = could not determine
# (report, never guess — an unavailable matrix is not an absent row).
#
# Advisory to the gate, like the health probe: `due:` asks the cycle to
# publish and commit a row, it never blocks work.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "unavailable:worktree-unreadable"; exit 2; }

. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(resolve_plan_binary)" || { echo "unavailable:no-runnable-plan-binary"; exit 2; }

host="${TILLANDSIAS_WORKSTATION:-}"
if [ -z "$host" ]; then
    host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo '')"
fi
host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
[ -n "$host" ] || { echo "unavailable:host-unresolvable"; exit 2; }

if ! matrix="$("$PLAN" capability-matrix 2>/dev/null)"; then
    echo "unavailable:capability-matrix-failed"
    exit 2
fi

if printf '%s\n' "$matrix" | grep -q "^host:$host	"; then
    echo "ok:capability-row-reported:$host"
    exit 0
fi
echo "due:no-capability-row:$host"
exit 1
