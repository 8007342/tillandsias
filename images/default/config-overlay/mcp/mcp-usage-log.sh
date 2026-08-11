#!/usr/bin/env bash
# Shared MCP usage-telemetry writer (packet 682-m8ek).
# @trace spec:forge-environment-discoverability, spec:methodology-accountability
# @trace order:575, order:682-m8ek
#
# ONE JSONL line per MCP tools/call, appended by EVERY server, so a cycle can
# report per-server usage volume — "are the servers used?" — as a companion to
# the plan expert's answer-rate. Before this file only forge-plan.sh logged, so
# cycle-metrics.sh could only report plan-expert calls and named the other
# servers `uninstrumented-see-682-m8ek`; this closes that.
#
# THE `server` FIELD IS THE LOAD-BEARING ADDITION. The 682-ym68 report noted the
# cycle-metrics `mcp:` line can only report REAL per-server counts once a record
# carries which server produced it. Every writer passes its own name, so the
# grouping is by construction and cannot be reconstructed by guessing from tool
# names (two servers expose `git_status`).
#
# RECORD GRAMMAR (pinned; agents/CI branch on the keys, never on prose):
#   {"ts":<utc>,"server":<name>,"tool":<name>,"outcome":<vocab>,"latency_ms":<n>?
#    ,"confidence":<str>?,"citations":<n>?}
# The base four keys (ts, server, tool, outcome) are ALWAYS present. latency_ms
# is added when a caller measured it. confidence/citations are the plan expert's
# richer trailer (forge-plan.sh only) — additive, so cycle-metrics.sh's
# `experts:` parser, which greps by `outcome`/`tool`, is unaffected.
#
# Outcome vocabulary (CLOSED SET, shared with record_expert_call):
#   answered | unsupported | degraded | error
#
# BEST-EFFORT BY CONSTRUCTION. Telemetry must never block or fail a tool call:
# the whole append is wrapped `|| true` and stderr is silenced, so a full
# tmpfs, a read-only log path, or an absent `date` cannot take down the surface
# being measured. A metric that can break what it measures is worse than none.

# mcp_log_usage <server> <tool> <outcome> [latency_ms] [confidence] [citations]
mcp_log_usage() {
    _mul_server="${1:-unknown}"
    _mul_tool="${2:-unknown}"
    _mul_outcome="${3:-answered}"
    _mul_latency="${4:-}"
    _mul_conf="${5:-}"
    _mul_cites="${6:-}"
    _mul_log="${TILLANDSIAS_EXPERT_USAGE_LOG:-/tmp/forge-expert-usage.jsonl}"
    {
        _mul_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
        _mul_line="$(printf '{"ts":"%s","server":"%s","tool":"%s","outcome":"%s"' \
            "$_mul_ts" "$_mul_server" "$_mul_tool" "$_mul_outcome")"
        case "$_mul_latency" in
            '' | *[!0-9]*) : ;;
            *) _mul_line="${_mul_line}$(printf ',"latency_ms":%s' "$_mul_latency")" ;;
        esac
        [ -n "$_mul_conf" ] && _mul_line="${_mul_line}$(printf ',"confidence":"%s"' "$_mul_conf")"
        case "$_mul_cites" in
            '' | *[!0-9]*) : ;;
            *) _mul_line="${_mul_line}$(printf ',"citations":%s' "$_mul_cites")" ;;
        esac
        _mul_line="${_mul_line}}"
        printf '%s\n' "$_mul_line" >>"$_mul_log"
    } 2>/dev/null || true
    return 0
}

# mcp_usage_source_shared — resolve + source this file from a sibling server.
# Kept here so the probe order is defined once. Callers do:
#   . "${BASH_SOURCE[0]%/*}/mcp-usage-log.sh" 2>/dev/null || true
# and then guarantee the symbol exists with the no-op fallback below.
:

# When a server could not source this file (path skew), it defines a no-op with
# the same name so the call sites stay unconditional and `set -e`-safe.
