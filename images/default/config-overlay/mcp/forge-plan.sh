#!/usr/bin/env bash
# MCP Server: Forge Plan Query Tool
# @trace order:456, spec:spec-traceability, invariant:plan_is_queried_via_mcp_server_avoiding_heuristic_parsing
# Communicates via JSON-RPC over stdin/stdout (MCP stdio transport)
#
# Tools:
#   plan_check       — integrity + schema validation
#   plan_status      — one packet's status line
#   plan_ready       — ready packets for a pickup role
#   plan_blocked_by  — packets directly blocked by a given packet
#   plan_closure     — everything transitively downstream of a packet
#   plan_burndown    — release-target children with statuses
#
# Wraps the compiled tillandsias-plan CLI for 100% accurate YAML queries.
# The binary is preferred over grep/python because it parses the plan
# ledger via serde_yaml with full dependency-graph awareness.

set -euo pipefail

# Detect the plan index — prefer TILLANDSIAS_PLAN_INDEX, fall back to
# the canonical repo plan/index.yaml.
PLAN_INDEX="${TILLANDSIAS_PLAN_INDEX:-}"
if [ -z "$PLAN_INDEX" ]; then
    for candidate in \
        "$HOME/src/tillandsias/plan/index.yaml" \
        "$HOME/tillandsias/plan/index.yaml" \
        "/opt/cheatsheets/plan-index.yaml"; do
        if [ -f "$candidate" ]; then
            PLAN_INDEX="$candidate"
            break
        fi
    done
fi

# Locate the tillandsias-plan binary
PLAN_BIN="${TILLANDSIAS_PLAN_BIN:-}"
if [ -z "$PLAN_BIN" ]; then
    for candidate in \
        "$HOME/.local/bin/tillandsias-plan" \
        "/usr/local/bin/tillandsias-plan" \
        "/usr/bin/tillandsias-plan"; do
        if [ -x "$candidate" ]; then
            PLAN_BIN="$candidate"
            break
        fi
    done
fi

# If we can't find the index or the binary, emit a startup warning
# but keep the server alive (MCP clients may retry).
if [ -z "$PLAN_INDEX" ] || [ ! -f "$PLAN_INDEX" ]; then
    PLAN_INDEX=""
fi
if [ -z "$PLAN_BIN" ] || [ ! -x "$PLAN_BIN" ]; then
    PLAN_BIN=""
fi

plan_query() {
    local cmd="$1"
    shift
    if [ -z "$PLAN_BIN" ]; then
        echo "ERROR: tillandsias-plan binary not found"
        return 1
    fi
    if [ -z "$PLAN_INDEX" ]; then
        echo "ERROR: plan/index.yaml not found"
        return 1
    fi
    "$PLAN_BIN" --index "$PLAN_INDEX" "$cmd" "$@" 2>&1 || true
}

# Read JSON-RPC requests from stdin, respond on stdout
while IFS= read -r line; do
    method=$(echo "$line" | jq -r '.method // empty')
    id=$(echo "$line" | jq -r '.id // empty')

    case "$method" in
        "initialize")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"forge-plan","version":"1.0.0"}}}'
            ;;
        "tools/list")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"tools":[
                {"name":"plan_check","description":"Run integrity + schema validation on the plan ledger (shell: tillandsias-plan check)","inputSchema":{"type":"object","properties":{}}},
                {"name":"plan_status","description":"Get the status line of a packet by id or order number","inputSchema":{"type":"object","properties":{"reference":{"type":"string"},"required":["reference"]}}},
                {"name":"plan_ready","description":"List ready packets, optionally filtered by pickup role","inputSchema":{"type":"object","properties":{"role":{"type":"string"}}}},
                {"name":"plan_blocked_by","description":"List packets directly blocked by a given packet","inputSchema":{"type":"object","properties":{"reference":{"type":"string"},"required":["reference"]}}},
                {"name":"plan_closure","description":"List everything transitively downstream of a given packet","inputSchema":{"type":"object","properties":{"reference":{"type":"string"},"required":["reference"]}}},
                {"name":"plan_burndown","description":"List all children of a milestone/release-target with their statuses","inputSchema":{"type":"object","properties":{"reference":{"type":"string"},"required":["reference"]}}}
            ]}}'
            ;;
        "tools/call")
            tool=$(echo "$line" | jq -r '.params.name')
            args=$(echo "$line" | jq -r '.params.arguments // {}')
            case "$tool" in
                "plan_check")
                    result=$(plan_query "check")
                    ;;
                "plan_status")
                    ref=$(echo "$args" | jq -r '.reference')
                    result=$(plan_query "status" "$ref")
                    ;;
                "plan_ready")
                    role=$(echo "$args" | jq -r '.role // ""')
                    if [ -n "$role" ]; then
                        result=$(plan_query "ready" "$role")
                    else
                        result=$(plan_query "ready")
                    fi
                    ;;
                "plan_blocked_by")
                    ref=$(echo "$args" | jq -r '.reference')
                    result=$(plan_query "blocked-by" "$ref")
                    ;;
                "plan_closure")
                    ref=$(echo "$args" | jq -r '.reference')
                    result=$(plan_query "blocked-closure" "$ref")
                    ;;
                "plan_burndown")
                    ref=$(echo "$args" | jq -r '.reference')
                    result=$(plan_query "burndown" "$ref")
                    ;;
                *)
                    result="Unknown tool: $tool"
                    ;;
            esac
            escaped=$(echo "$result" | jq -Rs .)
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"content":[{"type":"text","text":'"$escaped"'}]}}'
            ;;
        "prompts/list")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"prompts":[]}}'
            ;;
        "resources/list")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"resources":[]}}'
            ;;
        "resources/templates/list")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"resourceTemplates":[]}}'
            ;;
        "notifications/initialized")
            ;;
        *)
            if [ -n "$id" ]; then
                echo '{"jsonrpc":"2.0","id":"'"$id"'","error":{"code":-32601,"message":"Method not found: '"$method"'"}}'
            fi
            ;;
    esac
done
