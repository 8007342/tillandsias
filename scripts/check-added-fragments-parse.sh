#!/usr/bin/env bash
# @trace spec:ci-release, plan 698-7n6q, order:2223-afpl
#
# SHIM for scripts/lua/check-added-fragments-parse.lua, which is the decider
# (grammar, diff scope, bare-timestamp and parse rules all live there). This
# path stays only because the pre-push hook's plan-only lane, relay-preflight
# and three litmus tests name it; slice 2 of 2223-afpl rebinds them and deletes
# this file.
#
# With no runnable plan binary it keeps the .sh's refusal, never a green: the
# plan lane then demands the full gate (fail closed), as it did on every host
# without tillandsias-policy or yq.
set -uo pipefail
_afp_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_afp_here/plan-binary-probe.sh" 2>/dev/null || true
_afp_plan=""
command -v resolve_plan_binary >/dev/null 2>&1 \
    && _afp_plan="$(cd "$_afp_here/.." && resolve_plan_binary 2>/dev/null)" || _afp_plan=""
case "$_afp_plan" in ./*) _afp_plan="$_afp_here/../${_afp_plan#./}" ;; esac
if [ -n "$_afp_plan" ] && [ -f "$_afp_here/lua/check-added-fragments-parse.lua" ]; then
    # The checkout judged is the one this shim sits in, as the .sh's was: an
    # inherited TILLANDSIAS_REPO_ROOT (the litmus runner exports the real
    # checkout's) would root `script run` there and judge the wrong tree.
    TILLANDSIAS_REPO_ROOT="$(cd "$_afp_here/.." && pwd)" \
    TILLANDSIAS_SCRIPT_RUNNER_BIN="$_afp_plan" exec "$_afp_plan" script run \
        "$_afp_here/lua/check-added-fragments-parse.lua" -- "$@"
fi
echo "blocked:added-fragments-parse:no-validator"
echo "  why: no runnable tillandsias-plan (or no scripts/lua/check-added-fragments-parse.lua beside this shim)," >&2
echo "  so an unparseable fragment would pass unread." >&2
echo "  remedy: cargo build --release -p tillandsias-plan" >&2
exit 1
