#!/usr/bin/env bash
# NanoClawV2 host control surface bridge.
#
# Proxies JSON-RPC stdio through the host Unix socket to the
# tillandsias-nanoclawv2-mcp process started by the tray on launch.
#
# @trace spec:nanoclawv2-orchestration

set -euo pipefail

SOCKET="${TILLANDSIAS_NANOCLAW_SOCKET:-/run/host/tillandsias/nanoclaw.sock}"

if [[ -z "${TILLANDSIAS_NANOCLAW_SOCKET:-}" && ! -e "$SOCKET" ]]; then
    echo '{"jsonrpc":"2.0","error":{"code":-32000,"message":"TILLANDSIAS_NANOCLAW_SOCKET not set and default socket not found"}}'
    exit 1
fi

if [[ ! -e "$SOCKET" ]]; then
    echo '{"jsonrpc":"2.0","error":{"code":-32000,"message":"nanoclaw host socket does not exist: '"$SOCKET"'"}}'
    exit 1
fi

exec socat - "UNIX-CONNECT:$SOCKET" 2>/dev/null || {
    echo '{"jsonrpc":"2.0","error":{"code":-32000,"message":"Failed to connect to nanoclaw host socket"}}'
    exit 1
}
