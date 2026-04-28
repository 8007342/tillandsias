#!/usr/bin/env bash
# Browser MCP bridge: proxy stdio JSON-RPC through host control socket.
#
# Reads JSON-RPC messages from stdin (newline-delimited), wraps each as a
# ControlMessage::McpFrame, sends via Unix socket to the tray, and proxies
# responses back to stdout.
#
# @trace spec:host-browser-mcp, spec:default-image
# @cheatsheet web/mcp.md, runtime/networking.md

set -euo pipefail

if [[ -z "${TILLANDSIAS_CONTROL_SOCKET:-}" ]]; then
    echo '{"jsonrpc":"2.0","error":{"code":-32000,"message":"TILLANDSIAS_CONTROL_SOCKET not set"}}'
    exit 1
fi

if [[ ! -e "$TILLANDSIAS_CONTROL_SOCKET" ]]; then
    echo '{"jsonrpc":"2.0","error":{"code":-32000,"message":"TILLANDSIAS_CONTROL_SOCKET does not exist"}}'
    exit 1
fi

# Use socat to bridge stdin/stdout through the Unix socket.
# socat - UNIX-CONNECT:<socket> opens a bidirectional pipe.
socat - "UNIX-CONNECT:$TILLANDSIAS_CONTROL_SOCKET" 2>/dev/null || {
    echo '{"jsonrpc":"2.0","error":{"code":-32000,"message":"Failed to connect to control socket"}}'
    exit 1
}
