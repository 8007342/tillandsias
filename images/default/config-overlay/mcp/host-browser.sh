#!/usr/bin/env bash
# Browser MCP bridge: proxy stdio JSON-RPC to this lane's MCP socket.
#
# Relays newline-delimited JSON-RPC (NDJSON) verbatim in both directions
# over $TILLANDSIAS_CONTROL_SOCKET — which since order 505 is this LANE's
# own socket (/run/host/tillandsias-mcp/mcp.sock), not the shared postcard
# control socket. This is a raw socat pipe: no envelope, no length prefix,
# no Hello handshake. Attribution comes from which listener accepted the
# connection, so this script never names the project.
#
# (It previously claimed to wrap each line as a ControlMessage::McpFrame.
# It never did after order 505, and McpFrame on the shared control socket
# is now refused with ErrorCode::Unsupported.)
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
