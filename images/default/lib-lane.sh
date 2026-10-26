#!/usr/bin/env bash
# @trace spec:mcp-tool-socket, order:1863-eckw, order:1874-6p63
#
# lib-lane.sh — the lane MCP socket's state, with no side effects on source.
# Sourced by lib-common.sh (from its own directory) and by tillandsias-doctor,
# which cannot source lib-common.sh: that file runs CA trust and exports at
# source time.

# ── Host lane socket state (order 1863-eckw) ────────────────
# The lane MCP socket ($TILLANDSIAS_CONTROL_SOCKET) carries publish_local,
# browser.open and the host toolchains (flutter). A web-mode forge outlived the
# CLI that served it, and its socket refused every call for the session while
# the agent saw only "tool not shipped" or "flutter exits 69". Prints one
# token: ready | stale (socket file present, nothing accepts) | absent | unset.
lane_socket_state() {
    local sock="${TILLANDSIAS_CONTROL_SOCKET:-}"
    [[ -n "$sock" ]] || { echo unset; return 0; }
    [[ -S "$sock" ]] || { echo absent; return 0; }
    if python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(1); s.connect(sys.argv[1])' "$sock" 2>/dev/null; then
        echo ready
    else
        echo stale
    fi
}

# Wait (up to $1 seconds, default 10) for the lane socket to accept before the
# agent's MCP client starts: OpenCode tries host-browser once and never again.
wait_for_lane_socket() {
    local budget="${1:-10}" waited=0 state
    state="$(lane_socket_state)"
    while [[ "$state" != ready && "$state" != unset && "$waited" -lt "$budget" ]]; do
        sleep 1
        waited=$((waited + 1))
        state="$(lane_socket_state)"
    done
    trace_lifecycle "lane" "host lane socket ${state} after ${waited}s" 2>/dev/null || true
}
