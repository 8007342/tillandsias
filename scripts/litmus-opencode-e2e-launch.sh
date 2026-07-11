#!/usr/bin/env bash
# @trace spec:meta-orchestration, spec:forge-push-credential-channel
# litmus-opencode-e2e-launch.sh — STEP 3 of litmus:opencode-prompt-e2e-shape.
#
# Owns the full-vs-smoke decision (operator directive 2026-07-11: full
# /meta-orchestration in-forge e2e at most once per 4h; every other run
# downgrades to the cheap verify-only smoke prompt so provider tokens are
# not burned on repeated full cycles that then get killed at budget).
#
#   FULL  — allowed by scripts/forge-e2e-rate-limit.sh check full-meta.
#           Prompt: "Use the /meta-orchestration skill". 600s soft budget
#           extended by scripts/forge-liveness-probe.sh (order 265), 1500s
#           hard cap. Steps 4-6 of the litmus then assert commit+push deltas.
#   SMOKE — rate-limited path. Prompt invokes the skill's Smoke Mode
#           (skills/meta-orchestration/SKILL.md): verify-only, no plan
#           drain, no commits; the in-forge agent must print `MO-SMOKE: PASS`
#           as its verdict. 600s hard cap, no liveness extension needed.
#
# Writes the chosen mode to /tmp/opencode-e2e-mode so litmus steps 4-6 can
# skip delta assertions for smoke runs (a verify-only cycle pushes nothing).
# Prints FORGE_EXIT=<rc> as its last line; exit 0 only on a passing run.
set -uo pipefail

MODE_FILE=/tmp/opencode-e2e-mode
LOG=/tmp/opencode-e2e-forge.log
BH="$(cat /tmp/opencode-e2e-head-before 2>/dev/null || true)"

if scripts/forge-e2e-rate-limit.sh check full-meta >/dev/null 2>&1; then
    MODE=full
else
    MODE=smoke
    echo "NOTE: full-meta e2e rate-limited ($(scripts/forge-e2e-rate-limit.sh status full-meta)) — running smoke mode"
fi
echo "$MODE" > "$MODE_FILE"

if [ "$MODE" = full ]; then
    scripts/forge-e2e-rate-limit.sh record full-meta >/dev/null
    PROMPT="Use the /meta-orchestration skill"
    SOFT=600
    HARD=1500
else
    PROMPT="Use the /meta-orchestration skill in smoke mode (verify-only)"
    SOFT=600
    HARD=600
fi

./repeat --times 1 --agent opencode --prompt "$PROMPT" > "$LOG" 2>&1 &
RPID=$!
S="$(date +%s)"
while kill -0 "$RPID" 2>/dev/null; do
    E=$(( $(date +%s) - S ))
    if [ "$E" -ge "$HARD" ]; then
        kill "$RPID" 2>/dev/null
        echo "FORGE_EXIT=124 (hard cap ${HARD}s, mode=$MODE)"
        exit 1
    fi
    if [ "$MODE" = full ] && [ "$E" -ge "$SOFT" ]; then
        st="$(scripts/forge-liveness-probe.sh status --start-time "$S" --budget "$HARD" --before-head "$BH" 2>/dev/null || echo probe_error)"
        case "$st" in
            alive_*) ;;
            *)
                kill "$RPID" 2>/dev/null
                echo "FORGE_EXIT=125 (probe verdict $st past soft budget)"
                exit 1
                ;;
        esac
    fi
    sleep 10
done
wait "$RPID"
rc=$?
tail -5 "$LOG"

if [ "$MODE" = smoke ] && [ "$rc" -eq 0 ]; then
    if ! grep -q 'MO-SMOKE: PASS' "$LOG"; then
        echo "FORGE_EXIT=126 (smoke run exited 0 without MO-SMOKE: PASS verdict)"
        exit 1
    fi
fi

echo "FORGE_EXIT=$rc"
[ "$rc" -eq 0 ]
