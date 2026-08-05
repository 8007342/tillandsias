#!/usr/bin/env bash
# @trace order:605-u9g5, spec:forge-environment-discoverability
#
# register-experts.sh — idempotently register the forge-plan and project-info
# expert MCP servers with the Codex CLI.
#
# The supported Codex interface (verified against codex-cli 0.146.0 and the
# official manual at shaping time, order 600-xrqk) is:
#
#   codex mcp add <name> -- <command>
#   codex mcp list --json
#
# `add` writes a `[mcp_servers.<name>]` table into $CODEX_HOME/config.toml and
# replaces an existing table of the same name, so a double application leaves
# exactly one entry per server. auth.json is never touched (byte-preserved).
# The helper pre-checks `list` so an already-registered server is skipped
# instead of churned on every forge launch.
#
# Both the CLI binary and its environment are injectable so fixtures can pin
# the exact contract hermetically:
#
#   CODEX_BIN   — the codex binary (default: `codex` on PATH)
#   CODEX_HOME  — the codex home (default: ~/.codex)
#   TILLANDSIAS_CONFIG_OVERLAY_ROOT — config overlay root (default:
#                 /home/forge/.config-overlay); the expert servers are read
#                 from $ROOT/mcp/{forge-plan,project-info}.sh

set -euo pipefail

CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
MCP_DIR="${TILLANDSIAS_CONFIG_OVERLAY_ROOT:-/home/forge/.config-overlay}/mcp"

# codex mcp list refuses to run when $CODEX_HOME does not exist (verified
# against codex-cli 0.146.0), while `mcp add` creates it. Ensure the root
# exists up front so the pre-check and the add agree on every path.
mkdir -p "$CODEX_HOME" 2>/dev/null || true

# codex_mcp_registered <name> <command> — 0 when the server is already present
# as a stdio server with the exact command, non-zero otherwise. Parsed with jq
# because the helper must survive a malformed `list` output by refusing (the
# registration is then attempted and fails loud if `add` also refuses).
codex_mcp_registered() {
    local name="$1" command="$2"
    "$CODEX_BIN" mcp list --json 2>/dev/null | jq -e \
        --arg n "$name" --arg c "$command" \
        '.[] | select(.name == $n and .transport.type == "stdio" and .transport.command == $c)' \
        >/dev/null 2>&1
}

# codex_mcp_add <name> <command>
codex_mcp_add() {
    local name="$1" command="$2"
    "$CODEX_BIN" mcp add "$name" -- "$command"
}

# register_codex_experts — register every expert server, skipping the ones the
# CLI already lists with the exact command. Fails loud (non-zero) on any
# missing executable or CLI failure; the entrypoint wraps the whole call
# fail-soft so a registration defect can never block a forge launch.
register_codex_experts() {
    local name command
    while IFS= read -r name; do
        command="$MCP_DIR/$name.sh"
        if [ ! -x "$command" ]; then
            printf '%s\n' "[codex-mcp] missing executable $command for $name" >&2
            return 1
        fi
        if codex_mcp_registered "$name" "$command"; then
            printf '%s\n' "[codex-mcp] $name already registered ($command)"
        else
            codex_mcp_add "$name" "$command"
            printf '%s\n' "[codex-mcp] registered $name -> $command"
        fi
    done <<'SERVERS'
forge-plan
project-info
SERVERS
}

register_codex_experts
