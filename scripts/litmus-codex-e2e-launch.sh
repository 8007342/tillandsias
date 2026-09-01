#!/usr/bin/env bash
# @trace spec:meta-orchestration, spec:git-mirror-service
# @trace order:404
# litmus-codex-e2e-launch.sh — the CODEX sibling of litmus-opencode-e2e-launch.sh.
#
# Operator directive 2026-07-17: "Codex is also happy to run in non-interactive
# mode". The non-interactive lane already exists (`tillandsias --codex <proj>
# --prompt "<text>"` execs `codex exec` headless); what did not exist was an e2e
# smoke surface for it, so a Codex run could not be SCORED the way an OpenCode
# run is.
#
# PARITY IS THE POINT, and it is three specific things:
#
#   1. THE SAME BUDGET, NOT A SECOND ONE. Mode resolution comes from
#      scripts/lib-e2e-mode.sh against the SAME `full-meta` limiter class the
#      OpenCode lane uses. A codex full run consumes the shared 4h budget; it
#      does not get its own. Exit criterion 2 of order 404 says "shared, not
#      doubled", and a separate class would have been the easy wrong answer.
#   2. THE SAME VERDICT GRAMMAR. A smoke run that exits 0 without
#      `MO-SMOKE: PASS` is FORGE_EXIT=126, identical to the OpenCode lane, so
#      the two are directly comparable rather than merely both green.
#   3. THE SAME DE-ESCALATION RULE, inherited from the shared helper rather
#      than restated here — TILLANDSIAS_E2E_FORCE_MODE=smoke only ever makes a
#      run cheaper, and any other value is refused with exit 2.
#
# WHAT DIFFERS, deliberately: the harness flag (`--codex`), the log and
# mode-file paths (so a codex run never overwrites an opencode run's evidence),
# and FULL mode. Full-mode terminal attestation for codex is order 614-2gqx's
# scope, not this packet's, so full mode here records the budget and runs, but
# does not assert the MO-FULL marker the OpenCode lane checks. Asserting an
# attestation this lane has never been shown to emit would be a green light
# over an unverified surface.
#
# `--print-mode` resolves and prints `mode=<full|smoke>` without launching.
# Prints FORGE_EXIT=<rc> as its last line; exit 0 only on a passing run.
set -uo pipefail

MODE_FILE=/tmp/codex-e2e-mode
LOG=/tmp/codex-e2e-forge.log

PRINT_MODE=0
[ "${1:-}" = "--print-mode" ] && PRINT_MODE=1

# shellcheck source=scripts/lib-e2e-mode.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-e2e-mode.sh"
e2e_resolve_mode

if [ "$PRINT_MODE" = 1 ]; then
    echo "mode=$MODE"
    exit 0
fi

echo "$MODE" > "$MODE_FILE"

if [ "$MODE" = full ]; then
    scripts/forge-e2e-rate-limit.sh record full-meta >/dev/null
    PROMPT="Use the /meta-orchestration skill"
    HARD=1500
else
    PROMPT="Use the /meta-orchestration skill in smoke mode (verify-only)"
    HARD=600
fi

env TILLANDSIAS_NO_TRAY=1 tillandsias . --codex --prompt "$PROMPT" > "$LOG" 2>&1 &
RPID=$!
S="$(date +%s)"
while kill -0 "$RPID" 2>/dev/null; do
    E=$(( $(date +%s) - S ))
    if [ "$E" -ge "$HARD" ]; then
        kill "$RPID" 2>/dev/null
        echo "FORGE_EXIT=124 (hard cap ${HARD}s, mode=$MODE)"
        exit 1
    fi
    sleep 10
done
wait "$RPID"
rc=$?
tail -5 "$LOG"

# Identical to the OpenCode lane's smoke gate, verbatim in effect: a run that
# exits 0 without the typed verdict is NOT a pass. A provider can exit cleanly
# between tool calls having done nothing, and that must not score as green.
if [ "$MODE" = smoke ] && [ "$rc" -eq 0 ]; then
    if ! grep -q 'MO-SMOKE: PASS' "$LOG"; then
        echo "FORGE_EXIT=126 (smoke run exited 0 without MO-SMOKE: PASS verdict)"
        exit 1
    fi
fi

echo "FORGE_EXIT=$rc"
[ "$rc" -eq 0 ]
