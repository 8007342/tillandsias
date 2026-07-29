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

# Launch-state directory written by lib-common.sh::ensure_forge_experts.
# tmpfs — dies with the container. MUST agree with FORGE_EXPERTS_STATE_DIR.
FORGE_EXPERTS_STATE_DIR="${FORGE_EXPERTS_STATE_DIR:-/dev/shm/tillandsias-experts}"

# Canonical install destination for the plan expert binary, produced by
# lib-common.sh::ensure_forge_experts. This literal MUST stay identical on both
# sides — a wrapper probing a path that no build step produces is exactly what
# made this server dead on arrival when order 456 landed it. The agreement is
# pinned structurally by litmus:forge-plan-expert-build-shape.
PLAN_BIN_CANONICAL="$HOME/.local/bin/tillandsias-plan"

# Detect the plan index — prefer TILLANDSIAS_PLAN_INDEX, fall back to
# the canonical repo plan/index.yaml.
resolve_plan_index() {
    if [ -n "${TILLANDSIAS_PLAN_INDEX:-}" ] && [ -f "${TILLANDSIAS_PLAN_INDEX}" ]; then
        printf '%s\n' "$TILLANDSIAS_PLAN_INDEX"
        return 0
    fi
    for candidate in \
        "$HOME/src/tillandsias/plan/index.yaml" \
        "$HOME/tillandsias/plan/index.yaml" \
        "/opt/cheatsheets/plan-index.yaml"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    printf '\n'
}

# Locate the tillandsias-plan binary.
resolve_plan_bin() {
    if [ -n "${TILLANDSIAS_PLAN_BIN:-}" ] && [ -x "${TILLANDSIAS_PLAN_BIN}" ]; then
        printf '%s\n' "$TILLANDSIAS_PLAN_BIN"
        return 0
    fi
    for candidate in \
        "$PLAN_BIN_CANONICAL" \
        "/usr/local/bin/tillandsias-plan" \
        "/usr/bin/tillandsias-plan"; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    printf '\n'
}

# Render the experts launch state using the grammar pinned in lib-common.sh:
#   ready | building(<n>s) | degraded(<reason>)
experts_state_line() {
    local state="" started=0 now=0 elapsed=0
    if [ -r "$FORGE_EXPERTS_STATE_DIR/state" ]; then
        state="$(cat "$FORGE_EXPERTS_STATE_DIR/state" 2>/dev/null || true)"
    fi
    case "$state" in
        ready) printf 'ready\n' ;;
        building)
            started="$(cat "$FORGE_EXPERTS_STATE_DIR/started_at" 2>/dev/null || echo 0)"
            case "$started" in
                '' | *[!0-9]*) started=0 ;;
            esac
            now="$(date +%s 2>/dev/null || echo 0)"
            elapsed=$((now - started))
            [ "$elapsed" -ge 0 ] || elapsed=0
            printf 'building(%ss)\n' "$elapsed"
            ;;
        degraded:*) printf 'degraded(%s)\n' "${state#degraded:}" ;;
        *) printf 'degraded(not-built)\n' ;;
    esac
}

# Precise, actionable "binary absent" text. A bare "not found" told an agent
# nothing about whether the condition was transient or permanent, or which step
# was supposed to produce the binary. This names the build step, the canonical
# install path, and the current launch state.
binary_missing_error() {
    local state
    state="$(experts_state_line)"
    printf 'ERROR: the tillandsias-plan binary is not installed.\n'
    printf '  probed: %s, /usr/local/bin/tillandsias-plan, /usr/bin/tillandsias-plan\n' "$PLAN_BIN_CANONICAL"
    printf '  produced by: lib-common.sh::ensure_forge_experts — backgrounded at forge launch\n'
    printf '               immediately after clone_project_from_mirror; it runs\n'
    printf '               `cargo build --release -p tillandsias-plan` and installs the\n'
    printf '               artifact to %s.\n' "$PLAN_BIN_CANONICAL"
    printf '  experts state: %s\n' "$state"
    case "$state" in
        building*)
            printf '  TRANSIENT: the build is still running. Retry this tool in a few seconds.\n'
            ;;
        'degraded(no-plan-crate)')
            printf '  NOT APPLICABLE: this project has no crates/tillandsias-plan, so there is no\n'
            printf '  plan expert to build. The forge-plan MCP server has nothing to serve here.\n'
            ;;
        'degraded(not-built)')
            printf '  The expert build never started in this container (no project clone in this\n'
            printf '  lane, or the launch predates the build step). Build it by hand from the\n'
            printf '  checkout: cargo build --release -p tillandsias-plan &&\n'
            printf '  install -m0755 target/release/tillandsias-plan %s\n' "$PLAN_BIN_CANONICAL"
            ;;
        *)
            printf '  PERMANENT for this session. See /tmp/forge-lifecycle.log for the failure,\n'
            printf '  then rebuild by hand from the checkout:\n'
            printf '  cargo build --release -p tillandsias-plan &&\n'
            printf '  install -m0755 target/release/tillandsias-plan %s\n' "$PLAN_BIN_CANONICAL"
            ;;
    esac
    printf '  This never affected your session: expert construction is fail-soft by contract.\n'
}

# Resolved once at startup, then RE-RESOLVED lazily per call while unresolved.
# The expert build is backgrounded, so an MCP client that connects during the
# build would otherwise cache an empty path and stay broken for the whole
# session even after the binary appears.
PLAN_INDEX="$(resolve_plan_index)"
PLAN_BIN="$(resolve_plan_bin)"

plan_query() {
    local cmd="$1"
    shift
    [ -n "$PLAN_BIN" ] || PLAN_BIN="$(resolve_plan_bin)"
    [ -n "$PLAN_INDEX" ] || PLAN_INDEX="$(resolve_plan_index)"
    # NOTE: these paths return 0, deliberately. The call sites capture this
    # function with `result=$(plan_query ...)`, and this script runs under
    # `set -e` — a non-zero return there KILLS the MCP server mid-request, so
    # the client sees a dropped connection instead of the diagnostic. The error
    # text on stdout IS the signal; it is delivered as the tool result.
    if [ -z "$PLAN_BIN" ]; then
        binary_missing_error
        return 0
    fi
    if [ -z "$PLAN_INDEX" ]; then
        echo "ERROR: plan/index.yaml not found (probed \$TILLANDSIAS_PLAN_INDEX, \$HOME/src/tillandsias/plan/index.yaml, \$HOME/tillandsias/plan/index.yaml, /opt/cheatsheets/plan-index.yaml)"
        return 0
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
