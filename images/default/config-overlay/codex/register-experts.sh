#!/usr/bin/env bash
# @trace order:605-u9g5, spec:forge-environment-discoverability
#
# register-experts.sh — idempotently register the forge-plan, project-info, and
# host-browser MCP servers with the Codex CLI.
#
# The supported Codex interface (verified against codex-cli 0.146.0 and the
# official manual at shaping time, order 600-xrqk) is:
#
#   codex mcp add <name> [--env KEY=VALUE]... -- <command>
#   codex mcp list --json
#
# ENVIRONMENT IS NOT INHERITED (order 1667-jna9). Codex starts a stdio MCP
# server with only HOME LANG PATH PWD SHLVL USER (measured in codex-cli 0.162.1
# inside the forge image, 2026-10-14). host-browser.sh needs
# TILLANDSIAS_CONTROL_SOCKET to reach this lane's host socket; without it the
# server exits at startup and the lane has no publish_local, service_status or
# browser.open, while Claude lanes (which pass the full environment) do.
# A server line below may name variables to forward; each one set at
# registration is written as `--env NAME=VALUE`, which codex stores as a
# `[mcp_servers.<name>.env]` table and lists under `.transport.env`.
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

# codex_mcp_registered <name> <command> <env-json> — 0 when the server is
# already present as a stdio server with the exact command and every forwarded
# variable at its current value, non-zero otherwise. Parsed with jq
# because the helper must survive a malformed `list` output by refusing (the
# registration is then attempted and fails loud if `add` also refuses).
codex_mcp_registered() {
    local name="$1" command="$2" env_json="$3"
    "$CODEX_BIN" mcp list --json 2>/dev/null | jq -e \
        --arg n "$name" --arg c "$command" --argjson e "$env_json" \
        '.[] | select(.name == $n and .transport.type == "stdio" and .transport.command == $c
            and ((.transport.env // {}) | contains($e)))' \
        >/dev/null 2>&1
}

# codex_mcp_add <name> <command> [KEY=VALUE]...
codex_mcp_add() {
    local name="$1" command="$2" kv
    shift 2
    local env_args=()
    for kv in "$@"; do env_args+=(--env "$kv"); done
    "$CODEX_BIN" mcp add "$name" ${env_args[@]+"${env_args[@]}"} -- "$command"
}

# register_codex_experts — register every expert server, skipping the ones the
# CLI already lists with the exact command. Fails loud (non-zero) on any
# missing executable or CLI failure; the entrypoint wraps the whole call
# fail-soft so a registration defect can never block a forge launch.
register_codex_experts() {
    local name forward command var env_json
    while read -r name forward; do
        [ -n "$name" ] || continue
        command="$MCP_DIR/$name.sh"
        if [ ! -x "$command" ]; then
            printf '%s\n' "[codex-mcp] missing executable $command for $name" >&2
            return 1
        fi
        local kvs=()
        env_json='{}'
        for var in $forward; do
            [ -n "${!var:-}" ] || continue
            kvs+=("$var=${!var}")
            env_json="$(jq -cn --argjson e "$env_json" --arg k "$var" --arg v "${!var}" '$e + {($k): $v}')"
        done
        if codex_mcp_registered "$name" "$command" "$env_json"; then
            printf '%s\n' "[codex-mcp] $name already registered ($command)"
        else
            codex_mcp_add "$name" "$command" ${kvs[@]+"${kvs[@]}"}
            printf '%s\n' "[codex-mcp] registered $name -> $command${kvs[*]:+ (forwarding ${kvs[*]%%=*})}"
        fi
    done <<'SERVERS'
forge-plan
project-info
host-browser TILLANDSIAS_CONTROL_SOCKET
SERVERS
}

register_codex_experts
