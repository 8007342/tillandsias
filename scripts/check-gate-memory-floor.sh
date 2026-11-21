#!/usr/bin/env bash
# @trace order:1176-fn2p
# @trace order:2167-gmfl
#
# BOOTSTRAP for scripts/lua/check-gate-memory-floor.lua, which is the decider:
# refuse a gate BY NAME on a host with too little memory to start it (1176-fn2p).
# Every rule, verdict and exit code lives there; this file only finds a runner.
#
# WHY THIS STAYS SHELL. build.sh asks it at gate START, before anything is
# compiled, so on a fresh checkout there is no plan binary to run Lua with. The
# gate must still get a verdict it can score, and the readers know exactly one
# word for "nothing was asserted" (1354-apns), so the no-binary case prints a
# named could-not-run AND a terminal skip:, exit 3 — never "fine", and never a
# refusal that would block a host for lacking a binary the gate is about to build.
#
# The path is the entry point build.sh and the consumer fixtures name, so it is
# kept; the judged logic is not here. History: git log -p -- this file.
set -uo pipefail
_gmf_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 3

# shellcheck source=/dev/null
. "$_gmf_root/scripts/plan-binary-probe.sh" 2>/dev/null || true
if command -v resolve_plan_binary >/dev/null 2>&1 \
    && _gmf_plan="$(resolve_plan_binary 2>/dev/null)" && [ -n "$_gmf_plan" ]; then
    TILLANDSIAS_REPO_ROOT="$_gmf_root" exec "$_gmf_plan" script run \
        "$_gmf_root/scripts/lua/check-gate-memory-floor.lua" -- "$@"
fi

echo "could-not-run:gate-memory:no-plan-binary (no runnable tillandsias-plan yet, so scripts/lua/check-gate-memory-floor.lua cannot run; nothing is asserted about this host's memory)"
echo "skip:gate-memory:no-plan-binary"
exit 3
