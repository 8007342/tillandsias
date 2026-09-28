#!/usr/bin/env bash
# claude-pretooluse-command-policy.sh — THE TEMPORARY BRIDGE (order 1443-we89).
# @trace order:1443-we89, spec:command-policies
#
# Claude Code's PreToolUse hook for the Bash tool. Every decision is made by
# `tillandsias-plan policy classify-bash --hook`, which reads the hook JSON on
# stdin and answers in the hook contract: deny = exit 2 with the refusal on
# stderr, ask = the permissionDecision JSON on stdout, allow = exit 0, silent.
# Bash cannot be trusted to parse bash, so nothing is decided here.
#
#   --status   decision counts and the RETIREMENT CONDITION: this hook retires
#              when agents call the runtime directly (1443-8pur, 1443-r4cj), the
#              audit is quiet for 14 fleet days, and the operator flips the Bash
#              tool's default.
#   TILLANDSIAS_PRETOOLUSE_HOOK=off   the kill switch; allowed, and logged.
#
# A bridge that cannot run must not stop the fleet: with no runnable plan
# binary every command is ALLOWED, with a note on stderr.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLAN="${TILLANDSIAS_PLAN_BIN:-}"
if [ -z "$PLAN" ]; then
    PLAN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || PLAN=""
fi
case "$PLAN" in ./*) PLAN="$ROOT/${PLAN#./}" ;; esac
if [ -z "$PLAN" ] || ! "$PLAN" capabilities >/dev/null 2>&1; then
    if [ "${1:-}" = "--status" ]; then
        echo "blocked:pretooluse:no-plan-binary"
        exit 1
    fi
    echo "note:pretooluse:no-plan-binary — allowed unchecked (the bridge never stops the fleet)" >&2
    exit 0
fi
if [ "${1:-}" = "--status" ]; then
    exec "$PLAN" policy classify-bash --status
fi
exec "$PLAN" policy classify-bash --hook
