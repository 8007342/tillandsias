#!/usr/bin/env bash
# @trace order:1834-ujsf, spec:local-coding-delegation
# Entry for the rung aggregator (scripts/lua/local-delegate-ladder.lua):
#   scripts/local-delegate-ladder.sh [aggregate] [--ledger FILE]...
# Prints one line per (model, quant): rung, verdict, window counts. Reads the
# ledger only; promotion is computed, never asserted.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "${1:-}" = "aggregate" ] && shift
# shellcheck source=scripts/plan-binary-probe.sh
. "$HERE/plan-binary-probe.sh"
PLAN="$(cd "$HERE/.." && resolve_plan_binary)" || {
    # why: the aggregator runs on the plan binary's Lua runner and none runs here
    echo "refused:local-delegate-ladder:no-plan-binary"
    echo "  remedy: cargo build --release -p tillandsias-plan" >&2
    exit 1
}
case "$PLAN" in ./*) PLAN="$HERE/../${PLAN#./}" ;; esac
REPO="$(cd "$HERE/.." && pwd)"
TILLANDSIAS_REPO_ROOT="$REPO" exec "$PLAN" script run "$HERE/lua/local-delegate-ladder.lua" -- \
    aggregate --repo "$REPO" "$@"
