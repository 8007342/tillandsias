#!/usr/bin/env bash
# MCP Server: Git Tools for Tillandsias forge containers
# @trace spec:git-mirror-service, spec:layered-tools-overlay, spec:forge-shell-tools
# Communicates via JSON-RPC over stdin/stdout (MCP stdio transport)
#
# Tools:
#   git_status   — working tree status (paired with shell shortcut `tgs`)
#   git_log      — recent commits
#   git_diff     — unstaged changes
#   git_add      — stage files
#   git_commit   — create a commit
#   git_push     — push to the enclave git mirror (paired with shell shortcut `tgp`)
#   git_pull     — pull from the enclave git mirror
#   cache_report — summarize per-project cache sizes (paired with shell shortcut `cache-report`)
#
# Shell shortcuts (`tgs`, `tgp`, `cache-report`) live in shell-helpers.sh and
# call the same underlying primitives so agents and humans see identical
# behaviour from either entry point. See `tillandsias-help` for the full list.
#
# @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md
# @cheatsheet utils/podman-secrets.md

set -euo pipefail

# Cache constants — mirror the values set by /usr/local/lib/tillandsias/lib-common.sh
# so the MCP tools can run in contexts where lib-common.sh wasn't sourced (e.g.,
# stdio-only MCP processes started directly by the agent runtime).
# @trace spec:forge-cache-dual, spec:forge-shell-tools
: "${TILLANDSIAS_PROJECT_CACHE:=$HOME/.cache/tillandsias-project}"
: "${TILLANDSIAS_SHARED_CACHE:=/nix/store}"
: "${TILLANDSIAS_EPHEMERAL:=/tmp}"
: "${TILLANDSIAS_WORKSPACE:=$HOME/src}"

# git_push_via_mirror: push through the enclave git mirror.
# Forge containers have no external network; pushes go to the git-service
# container which re-pushes to GitHub with the host-keyring token.
# @trace spec:git-mirror-service, spec:forge-shell-tools
git_push_via_mirror() {
    local remote="${1:-origin}" branch="${2:-}"
    if [ -z "$branch" ]; then
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    fi
    if [ -z "$branch" ]; then
        echo "Not on any branch; cannot push" >&2
        return 1
    fi
    git push "$remote" "$branch" 2>&1
}

# git_pull_via_mirror: pull through the enclave git mirror.
# @trace spec:git-mirror-service, spec:forge-shell-tools
git_pull_via_mirror() {
    local remote="${1:-origin}" branch="${2:-}"
    if [ -z "$branch" ]; then
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    fi
    if [ -z "$branch" ]; then
        echo "Not on any branch; cannot pull" >&2
        return 1
    fi
    git pull --ff-only "$remote" "$branch" 2>&1
}

# cache_report_text: per-tier cache size summary as a human-readable table.
# Reads the cache constants exported above. No side effects.
# @trace spec:forge-cache-dual, spec:forge-shell-tools
cache_report_text() {
    {
        printf '%-22s %-44s %-10s %s\n' "Tier" "Path" "Size" "Persists?"
        printf '%s\n' "$(printf -- '-%.0s' {1..90})"
        for entry in \
            "shared|$TILLANDSIAS_SHARED_CACHE|yes (RO)" \
            "project|$TILLANDSIAS_PROJECT_CACHE|yes" \
            "workspace|$TILLANDSIAS_WORKSPACE|yes (git)" \
            "ephemeral|$TILLANDSIAS_EPHEMERAL|no"; do
            IFS='|' read -r tier path persists <<<"$entry"
            local size="—"
            if [ -d "$path" ]; then
                size=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
            fi
            printf '%-22s %-44s %-10s %s\n' "$tier" "$path" "$size" "$persists"
        done
    }
}

# Read JSON-RPC requests from stdin, respond on stdout
while IFS= read -r line; do
    method=$(echo "$line" | jq -r '.method // empty')
    id=$(echo "$line" | jq -r '.id // empty')

    case "$method" in
        "initialize")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"git-tools","version":"1.0.0"}}}'
            ;;
        "tools/list")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"tools":[{"name":"git_status","description":"Show working tree status (shell: tgs)","inputSchema":{"type":"object","properties":{}}},{"name":"git_log","description":"Show recent commits","inputSchema":{"type":"object","properties":{"count":{"type":"number","default":20}}}},{"name":"git_diff","description":"Show unstaged changes","inputSchema":{"type":"object","properties":{}}},{"name":"git_add","description":"Stage files","inputSchema":{"type":"object","properties":{"files":{"type":"string"}},"required":["files"]}},{"name":"git_commit","description":"Create a commit","inputSchema":{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}},{"name":"git_push","description":"Push current branch via the enclave git mirror (shell: tgp)","inputSchema":{"type":"object","properties":{"remote":{"type":"string","default":"origin"},"branch":{"type":"string"}}}},{"name":"git_pull","description":"Pull current branch (fast-forward only) via the enclave git mirror","inputSchema":{"type":"object","properties":{"remote":{"type":"string","default":"origin"},"branch":{"type":"string"}}}},{"name":"cache_report","description":"Summarize per-tier cache sizes (shell: cache-report)","inputSchema":{"type":"object","properties":{}}}]}}'
            ;;
        "tools/call")
            tool=$(echo "$line" | jq -r '.params.name')
            args=$(echo "$line" | jq -r '.params.arguments // {}')
            case "$tool" in
                "git_status")
                    result=$(git status --short 2>&1 || echo "Not a git repo")
                    ;;
                "git_log")
                    count=$(echo "$args" | jq -r '.count // 20')
                    result=$(git log --oneline -"$count" 2>&1 || echo "No git history")
                    ;;
                "git_diff")
                    result=$(git diff 2>&1 || echo "No changes")
                    ;;
                "git_add")
                    files=$(echo "$args" | jq -r '.files')
                    result=$(git add $files 2>&1 && echo "Staged: $files" || echo "Failed to stage")
                    ;;
                "git_commit")
                    msg=$(echo "$args" | jq -r '.message')
                    result=$(git commit -m "$msg" 2>&1 || echo "Commit failed")
                    ;;
                "git_push")
                    # @trace spec:git-mirror-service, spec:forge-shell-tools
                    remote=$(echo "$args" | jq -r '.remote // "origin"')
                    branch=$(echo "$args" | jq -r '.branch // ""')
                    result=$(git_push_via_mirror "$remote" "$branch" || echo "Push failed")
                    ;;
                "git_pull")
                    # @trace spec:git-mirror-service, spec:forge-shell-tools
                    remote=$(echo "$args" | jq -r '.remote // "origin"')
                    branch=$(echo "$args" | jq -r '.branch // ""')
                    result=$(git_pull_via_mirror "$remote" "$branch" || echo "Pull failed")
                    ;;
                "cache_report")
                    # @trace spec:forge-cache-dual, spec:forge-shell-tools
                    result=$(cache_report_text)
                    ;;
                *)
                    result="Unknown tool: $tool"
                    ;;
            esac
            # Escape the result for JSON
            escaped=$(echo "$result" | jq -Rs .)
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"content":[{"type":"text","text":'"$escaped"'}]}}'
            ;;
        "prompts/list")
            # @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
            # MCP spec: servers must respond to prompts/list even if they
            # declare no prompts capability. Without this, OpenCode waits 60s
            # for a reply, timing out the UI's /command endpoint and causing
            # a full-UI freeze on session load.
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"prompts":[]}}'
            ;;
        "resources/list")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"resources":[]}}'
            ;;
        "resources/templates/list")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"resourceTemplates":[]}}'
            ;;
        "notifications/initialized")
            # Client acknowledgment - no response needed
            ;;
        *)
            # @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
            # Unknown method — respond with MCP's standard "method not found"
            # error instead of silently ignoring. Silence causes 60s timeouts
            # in the client and hangs the UI.
            if [ -n "$id" ]; then
                echo '{"jsonrpc":"2.0","id":"'"$id"'","error":{"code":-32601,"message":"Method not found: '"$method"'"}}'
            fi
            ;;
    esac
done
