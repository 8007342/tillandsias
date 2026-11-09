#!/usr/bin/env bash
# freshness: added 2026-08-28 linux-yoga (order 823-u3k9)
# @trace order:823-u3k9, order:799-j4xd, order:801-m9tk
#
# lib-mcp-build-id.sh — "which build of this server am I talking to?"
#
# WHY. A fix in a file does not reach a process that already read it. An MCP
# stdio server is a LONG-LIVED process: the harness launches it once at session
# start and every later tool call goes to that same process, running whatever
# the file said then. 799-j4xd fixed forge-plan.sh's refusal text on 2026-08-17;
# on 2026-08-18 a macuahuitl session still received the pre-fix prose, because
# its server had been launched before the fix landed. Every health signal read
# green throughout.
#
# It reads green BY CONSTRUCTION: check-mcp-expert-health.sh launches its OWN
# instance from the registration, so the process it measures always reflects the
# current file. It is a syntax-and-registration check wearing the name of a
# health check, and no amount of hardening it can change that — the process the
# agent reaches is simply not the process it probes.
#
# THE ONLY THING THAT CAN CLOSE IT is for the running process to say which build
# it is. So the server computes an id ONCE, at startup, from the file it was
# launched from, and carries it for its lifetime; the checker computes the same
# id from the same file NOW. Equal means the process is current. Different means
# the process predates the file — a NAMED state, not a green one.
#
# SCOPE, stated rather than implied: the id covers the server script FILE. A
# change confined to a lib the server sources is not covered, and widening the
# id to hash every sibling lib would make unrelated edits report drift, which is
# the false-positive inversion of this same defect. One file, one falsifiable
# claim.
#
# `unknown` is a real value. No digest tool (since 2049-vv58: no plan binary) means the id is UNKNOWABLE, and an
# unknowable id must never compare equal to anything — a checker seeing
# `unknown` on either side reports that it could not tell, never `current`.

# tillandsias_mcp_build_id <file> -> 12 hex chars, or `unknown`
#
# ORDER 2049-vv58 (openspec forge-lua-helpers D3.4): one call to the plan
# binary's `hash sha256 <file>` replaces the sha256sum / shasum / cksum chain
# and its `cut`/`tr`. NOT a Lua module, deliberately: the Lua fs door is
# confined to the repository root, and the file hashed here is the MCP server
# script under /home/forge/.config-overlay/mcp/, outside any project, so
# `hash.sha256(fs.read(...))` would be refused and read `unknown` in every
# forge. The digest is byte-identical to sha256sum's. Without the binary the id
# is UNKNOWABLE and says so; no second implementation.
tillandsias_mcp_build_id() {
    _mbi_file="${1:-}"
    if [ -z "$_mbi_file" ] || [ ! -r "$_mbi_file" ]; then
        printf 'unknown\n'
        return 0
    fi
    _mbi_plan="${TILLANDSIAS_PLAN_BIN:-tillandsias-plan}"
    _mbi_sum=""
    if command -v "$_mbi_plan" >/dev/null 2>&1; then
        _mbi_sum="$("$_mbi_plan" hash sha256 "$_mbi_file" 2>/dev/null)" || _mbi_sum=""
    fi
    case "$_mbi_sum" in
        '' | *[!0-9a-f]*) printf 'unknown\n'; return 0 ;;
    esac
    printf '%.12s\n' "$_mbi_sum"
    return 0
}
