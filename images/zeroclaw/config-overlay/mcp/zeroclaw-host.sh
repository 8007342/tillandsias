#!/usr/bin/env bash
# ZeroClaw host control surface bridge.
#
# Proxies JSON-RPC stdio through the host Unix socket to the
# tillandsias-zeroclaw process started by the tray on launch.
#
# @trace spec:zeroclaw-orchestration

set -euo pipefail

SOCKET="${TILLANDSIAS_ZEROCLAW_SOCKET:-/run/host/tillandsias/zeroclaw.sock}"

if [[ -z "${TILLANDSIAS_ZEROCLAW_SOCKET:-}" && ! -e "$SOCKET" ]]; then
    echo '{"jsonrpc":"2.0","error":{"code":-32000,"message":"TILLANDSIAS_ZEROCLAW_SOCKET not set and default socket not found"}}'
    exit 1
fi

if [[ ! -e "$SOCKET" ]]; then
    echo '{"jsonrpc":"2.0","error":{"code":-32000,"message":"zeroclaw host socket does not exist: '"$SOCKET"'"}}'
    exit 1
fi

exec socat - "UNIX-CONNECT:$SOCKET" 2>/dev/null || {
    echo '{"jsonrpc":"2.0","error":{"code":-32000,"message":"Failed to connect to zeroclaw host socket"}}'
    exit 1
}
