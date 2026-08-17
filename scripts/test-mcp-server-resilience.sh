#!/usr/bin/env bash
# @trace spec:forge-environment-discoverability
#
# Request-fault ISOLATION for the stdio MCP expert servers: a fault in ONE
# request (a SIGPIPE'd pipeline, a malformed JSON line) must fail THAT request
# at worst — never the server. 2026-08-15 the exact opposite shipped live: a
# read_file(offset,limit) whose `tail | head` took SIGPIPE under
# `set -euo pipefail` killed project-info mid-session, the client saw
# "MCP error -32000: Connection closed", and every project-info tool
# deregistered for the rest of the session.
#
# GRAMMAR (exactly one line on stdout, last line):
#   ok:project-info-survives-sigpipe
#   ok:mcp-servers-survive-malformed-line
#   fail:<detail>
#
# Exit 0 on ok, 1 on fail.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_INFO="$ROOT/images/default/config-overlay/mcp/project-info.sh"
FORGE_PLAN="$ROOT/images/default/config-overlay/mcp/forge-plan.sh"
MODE="${1:-}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcp-resilience.XXXXXX")" || {
    echo "fail:mktemp"
    exit 1
}
trap 'rm -rf "$WORK"' EXIT

case "$MODE" in
    sigpipe)
        # A fixture long enough that `tail -n +100 | head -n 5` leaves tail
        # tens of thousands of lines still to write when head exits — the
        # guaranteed-SIGPIPE window that killed the live server (offset 32484
        # of a ~51k-line plan/index.yaml).
        seq 1 40000 > "$WORK/big.txt"
        {
            printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"%s","offset":100,"limit":5}}}\n' "$WORK/big.txt"
            printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"project_type","arguments":{"path":"."}}}\n'
        } > "$WORK/requests.jsonl"
        (cd "$ROOT" && bash "$PROJECT_INFO" < "$WORK/requests.jsonl" > "$WORK/out.jsonl" 2>"$WORK/err.txt")
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "fail:server-died-rc-$rc"
            exit 1
        fi
        grep -q '"id":1' "$WORK/out.jsonl" || { echo "fail:first-request-unanswered"; exit 1; }
        grep -q '"id":2' "$WORK/out.jsonl" || { echo "fail:followup-request-unanswered"; exit 1; }
        echo "ok:project-info-survives-sigpipe"
        ;;
    malformed)
        {
            printf 'this is not json\n'
            printf '{"jsonrpc":"2.0","id":7,"method":"tools/list"}\n'
        } > "$WORK/requests.jsonl"
        for server in "$PROJECT_INFO" "$FORGE_PLAN"; do
            (cd "$ROOT" && bash "$server" < "$WORK/requests.jsonl" > "$WORK/out.jsonl" 2>"$WORK/err.txt")
            rc=$?
            if [ "$rc" -ne 0 ]; then
                echo "fail:$(basename "$server")-died-on-malformed-line-rc-$rc"
                exit 1
            fi
            grep -q '"id":7' "$WORK/out.jsonl" || {
                echo "fail:$(basename "$server")-no-reply-after-malformed-line"
                exit 1
            }
        done
        echo "ok:mcp-servers-survive-malformed-line"
        ;;
    *)
        echo "fail:usage-sigpipe-or-malformed"
        exit 1
        ;;
esac
exit 0
