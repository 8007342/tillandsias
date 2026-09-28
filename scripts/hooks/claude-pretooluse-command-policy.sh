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
# A binary that RUNS but predates `classify-bash` answers with a usage error and
# exit 2, and exit 2 is the hook contract's DENY: measured on the land83 relay,
# where it blocked every Bash call in the relaying session. So a deny counts
# only when it carries its verdict token; any other failure is "could not
# classify", which the bridge allows with a note, like a missing binary.
input="$(cat)"
errf="$(mktemp "${TMPDIR:-/tmp}/pretooluse-err.XXXXXX")" || errf=/dev/null
out="$("$PLAN" policy classify-bash --hook <<<"$input" 2>"$errf")"
rc=$?
err=""
[ "$errf" = /dev/null ] || { err="$(cat "$errf")"; rm -f "$errf"; }
if [ "$rc" -eq 0 ]; then
    [ -z "$out" ] || printf '%s\n' "$out"
    exit 0
fi
case "$err" in
    *refused:bash-policy:*)
        printf '%s\n' "$err" >&2
        exit 2
        ;;
esac
echo "note:pretooluse:could-not-classify:rc=$rc — allowed unchecked (rebuild the plan binary: it may predate policy classify-bash)" >&2
exit 0
