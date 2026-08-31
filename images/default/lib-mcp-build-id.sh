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
# `unknown` is a real value. No digest tool means the id is UNKNOWABLE, and an
# unknowable id must never compare equal to anything — a checker seeing
# `unknown` on either side reports that it could not tell, never `current`.

# tillandsias_mcp_build_id <file> -> 12 hex chars, or `unknown`
tillandsias_mcp_build_id() {
    _mbi_file="${1:-}"
    if [ -z "$_mbi_file" ] || [ ! -r "$_mbi_file" ]; then
        printf 'unknown\n'
        return 0
    fi
    _mbi_sum=""
    if command -v sha256sum >/dev/null 2>&1; then
        _mbi_sum="$(sha256sum "$_mbi_file" 2>/dev/null | cut -d' ' -f1)"
    elif command -v shasum >/dev/null 2>&1; then
        _mbi_sum="$(shasum -a 256 "$_mbi_file" 2>/dev/null | cut -d' ' -f1)"
    elif command -v cksum >/dev/null 2>&1; then
        # Weaker, and deliberately still not `unknown`: cksum distinguishes the
        # before/after of a real edit, which is the whole question here.
        _mbi_sum="$(cksum "$_mbi_file" 2>/dev/null | tr -d ' ' | tr -c '0-9a-f' 'f')"
    fi
    case "$_mbi_sum" in
        '' | *[!0-9a-f]*) printf 'unknown\n'; return 0 ;;
    esac
    printf '%.12s\n' "$_mbi_sum"
    return 0
}
