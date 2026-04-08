#!/usr/bin/env bash
# MCP Server: Git Tools for Tillandsias forge containers
# @trace spec:git-mirror-service, spec:layered-tools-overlay
# Communicates via JSON-RPC over stdin/stdout (MCP stdio transport)
#
# Tools: git_status, git_log, git_diff, git_add, git_commit

set -euo pipefail

# Read JSON-RPC requests from stdin, respond on stdout
while IFS= read -r line; do
    method=$(echo "$line" | jq -r '.method // empty')
    id=$(echo "$line" | jq -r '.id // empty')

    case "$method" in
        "initialize")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"git-tools","version":"1.0.0"}}}'
            ;;
        "tools/list")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"tools":[{"name":"git_status","description":"Show working tree status","inputSchema":{"type":"object","properties":{}}},{"name":"git_log","description":"Show recent commits","inputSchema":{"type":"object","properties":{"count":{"type":"number","default":20}}}},{"name":"git_diff","description":"Show unstaged changes","inputSchema":{"type":"object","properties":{}}},{"name":"git_add","description":"Stage files","inputSchema":{"type":"object","properties":{"files":{"type":"string"}},"required":["files"]}},{"name":"git_commit","description":"Create a commit","inputSchema":{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}}]}}'
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
                *)
                    result="Unknown tool: $tool"
                    ;;
            esac
            # Escape the result for JSON
            escaped=$(echo "$result" | jq -Rs .)
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"content":[{"type":"text","text":'"$escaped"'}]}}'
            ;;
        "notifications/initialized")
            # Client acknowledgment - no response needed
            ;;
    esac
done
