#!/usr/bin/env bash
# Claude delegate MCP server for Tillandsias.
# @trace spec:methodology-accountability
#
# Exposes the existing claude-delegate helper over MCP stdio so agents can
# offload bounded audits, patch drafts, and JSON summaries to Claude workers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DELEGATE_SCRIPT="$REPO_ROOT/scripts/claude-delegate.sh"

json_escape() {
    jq -Rs . <<<"${1:-}"
}

rpc_send() {
    local payload="$1"
    printf '%s\n' "$payload"
}

rpc_result() {
    local id="$1"
    local result_json="$2"
    rpc_send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":$result_json}"
}

rpc_error() {
    local id="$1"
    local code="$2"
    local message="$3"
    rpc_send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":$code,\"message\":$(json_escape "$message")}}"
}

tools_list() {
    local id="$1"
    printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"claude.audit","description":"Run a read-only Claude audit and return concise findings.","inputSchema":{"type":"object","properties":{"task":{"type":"string"},"model":{"type":"string"},"effort":{"type":"string"}},"required":["task"]}},{"name":"claude.patch_draft","description":"Ask Claude for a minimal patch draft without editing files.","inputSchema":{"type":"object","properties":{"task":{"type":"string"},"model":{"type":"string"},"effort":{"type":"string"}},"required":["task"]}},{"name":"claude.json","description":"Ask Claude for structured JSON analysis.","inputSchema":{"type":"object","properties":{"task":{"type":"string"},"model":{"type":"string"},"effort":{"type":"string"}},"required":["task"]}}]}}\n' "$id"
}

delegate_mode() {
    case "$1" in
        claude.audit) printf '%s' audit ;;
        claude.patch_draft) printf '%s' patch-draft ;;
        claude.json) printf '%s' json ;;
        *) return 1 ;;
    esac
}

call_delegate() {
    local mode="$1"
    local task="$2"
    local model="${3:-}"
    local effort="${4:-}"
    local timeout_secs="${CLAUDE_DELEGATE_TIMEOUT:-180}"
    local tmp_out tmp_err
    tmp_out="$(mktemp)"
    tmp_err="$(mktemp)"

    local -a env_prefix=()
    if [[ -n "$model" ]]; then
        env_prefix+=(CLAUDE_DELEGATE_MODEL="$model")
    fi
    if [[ -n "$effort" ]]; then
        env_prefix+=(CLAUDE_DELEGATE_EFFORT="$effort")
    fi

    if ! timeout -k 5s "${timeout_secs}s" env "${env_prefix[@]}" "$DELEGATE_SCRIPT" "$mode" "$task" >"$tmp_out" 2>"$tmp_err"; then
        local stderr
        stderr="$(cat "$tmp_err")"
        rm -f "$tmp_out" "$tmp_err"
        printf 'Error: %s' "${stderr:-Claude delegate failed}" >&2
        return 1
    fi

    cat "$tmp_out"
    rm -f "$tmp_out" "$tmp_err"
}

while IFS= read -r line; do
    method="$(jq -r '.method // empty' <<<"$line")"
    id="$(jq -r '.id // empty' <<<"$line")"

    case "$method" in
        initialize)
            rpc_send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"claude-delegate-mcp\",\"version\":\"1.0.0\"}}}"
            ;;
        tools/list)
            tools_list "$id"
            ;;
        tools/call)
            tool="$(jq -r '.params.name // empty' <<<"$line")"
            args="$(jq -c '.params.arguments // {}' <<<"$line")"
            task="$(jq -r '.task // empty' <<<"$args")"
            model="$(jq -r '.model // empty' <<<"$args")"
            effort="$(jq -r '.effort // empty' <<<"$args")"

            if [[ -z "$task" ]]; then
                rpc_error "$id" -32602 "tools/call requires task"
                continue
            fi

            if ! mode="$(delegate_mode "$tool")"; then
                rpc_error "$id" -32601 "Unknown tool: $tool"
                continue
            fi

            if ! output="$(call_delegate "$mode" "$task" "$model" "$effort")"; then
                rpc_send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"content\":[{\"type\":\"text\",\"text\":$(json_escape "Claude delegate failed for $tool")}],\"isError\":true}}"
                continue
            fi

            rpc_result "$id" "{\"content\":[{\"type\":\"text\",\"text\":$(json_escape "$output")}]}"
            ;;
        prompts/list)
            rpc_send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"prompts\":[]}}"
            ;;
        resources/list)
            rpc_send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"resources\":[]}}"
            ;;
        resources/templates/list)
            rpc_send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"resourceTemplates\":[]}}"
            ;;
        notifications/initialized)
            ;;
        *)
            if [[ -n "$id" ]]; then
                rpc_error "$id" -32601 "Method not found: $method"
            fi
            ;;
    esac
done
