#!/usr/bin/env bash
# MCP Server: Project Info for Tillandsias forge containers
# @trace spec:layered-tools-overlay, spec:forge-environment-discoverability
# Communicates via JSON-RPC over stdin/stdout (MCP stdio transport)
#
# Tools: project_structure, file_summary, search_code, project_list, project_info,
#        project_type, project_metadata

set -euo pipefail

# ── Project type detection ──────────────────────────────────────
# @trace spec:forge-environment-discoverability
# Detects project type by examining canonical marker files.
# Returns a list of detected types (may be multiple for polyglot projects).
detect_project_types() {
    local project_dir="${1:-.}"
    local types=""

    # Detect by marker files (order matters for common polyglots)
    [ -f "$project_dir/Cargo.toml" ] && types="$types rust"
    [ -f "$project_dir/Cargo.lock" ] && types="$types rust-workspace"
    [ -f "$project_dir/go.mod" ] && types="$types go"
    [ -f "$project_dir/go.sum" ] && types="$types go"
    [ -f "$project_dir/package.json" ] && types="$types node"
    [ -f "$project_dir/package-lock.json" ] && types="$types node-npm"
    [ -f "$project_dir/yarn.lock" ] && types="$types node-yarn"
    [ -f "$project_dir/pnpm-lock.yaml" ] && types="$types node-pnpm"
    [ -f "$project_dir/bun.lockb" ] && types="$types node-bun"
    [ -f "$project_dir/requirements.txt" ] && types="$types python"
    [ -f "$project_dir/setup.py" ] && types="$types python"
    [ -f "$project_dir/setup.cfg" ] && types="$types python"
    [ -f "$project_dir/pyproject.toml" ] && types="$types python-pyproject"
    [ -f "$project_dir/poetry.lock" ] && types="$types python-poetry"
    [ -f "$project_dir/Pipfile" ] && types="$types python-pipenv"
    [ -f "$project_dir/pom.xml" ] && types="$types java-maven"
    [ -f "$project_dir/build.gradle" ] || [ -f "$project_dir/build.gradle.kts" ] && types="$types java-gradle"
    [ -f "$project_dir/CMakeLists.txt" ] && types="$types cmake"
    [ -f "$project_dir/Makefile" ] && types="$types make"
    [ -f "$project_dir/Dockerfile" ] && types="$types docker"
    [ -f "$project_dir/flake.nix" ] && types="$types nix"
    [ -f "$project_dir/pubspec.yaml" ] && types="$types dart-flutter"
    [ -d "$project_dir/.git" ] && types="$types git"

    # Trim leading/trailing whitespace and deduplicate
    echo "$types" | xargs | tr ' ' '\n' | sort -u | tr '\n' ',' | sed 's/,$//'
}

# ── Project metadata extraction ──────────────────────────────────
# @trace spec:forge-environment-discoverability
# Extracts structured metadata about a project.
get_project_metadata() {
    local project_dir="${1:-.}"
    local project_name="${2:-$(basename "$project_dir")}"

    # Description from README
    local description=""
    if [ -f "$project_dir/README.md" ]; then
        description=$(head -1 "$project_dir/README.md" | sed 's/^# //' | sed 's/^## //' | head -c 100)
    fi

    # Project type
    local project_type
    project_type=$(detect_project_types "$project_dir")

    # Is Tillandsias-managed
    local is_managed="false"
    [ -f "$project_dir/.tillandsias/config.toml" ] && is_managed="true"

    # Output as structured JSON
    cat <<EOF
{
  "name": "$project_name",
  "path": "$project_dir",
  "description": "$description",
  "types": "$project_type",
  "managed": $is_managed,
  "has_readme": $([ -f "$project_dir/README.md" ] && echo "true" || echo "false"),
  "has_git": $([ -d "$project_dir/.git" ] && echo "true" || echo "false"),
  "has_config": $([ -f "$project_dir/.tillandsias/config.toml" ] && echo "true" || echo "false")
}
EOF
}

# ── Workspace discovery (sibling projects) ───────────────────
# @trace gap:ON-006
# Discovers sibling git projects in the parent directory of the current project.
# Returns JSON array of projects with basic metadata (name, description, managed).
discover_sibling_projects() {
    local current_project_dir="${1:-.}"
    local parent_dir
    parent_dir=$(dirname "$current_project_dir")

    local projects_json=""

    # Scan parent directory for git projects
    if [ -d "$parent_dir" ]; then
        for project_dir in "$parent_dir"/*; do
            # Skip if not a directory or doesn't have .git
            if [ ! -d "$project_dir" ] || [ ! -d "$project_dir/.git" ]; then
                continue
            fi

            # Skip the current project itself
            if [ "$(realpath "$project_dir")" = "$(realpath "$current_project_dir")" ]; then
                continue
            fi

            local project_name
            project_name=$(basename "$project_dir")

            # Extract description from README
            local description=""
            if [ -f "$project_dir/README.md" ]; then
                description=$(head -1 "$project_dir/README.md" | sed 's/^# //' | sed 's/^## //' | head -c 100)
            fi

            # Check if Tillandsias-managed
            local is_managed="false"
            [ -f "$project_dir/.tillandsias/config.toml" ] && is_managed="true"

            # Build JSON object for this project
            if [ -z "$projects_json" ]; then
                projects_json="{\"name\":\"$project_name\",\"path\":\"$project_dir\",\"description\":\"$description\",\"managed\":$is_managed}"
            else
                projects_json="$projects_json,{\"name\":\"$project_name\",\"path\":\"$project_dir\",\"description\":\"$description\",\"managed\":$is_managed}"
            fi
        done
    fi

    # Return as JSON array
    if [ -n "$projects_json" ]; then
        echo "[$projects_json]"
    else
        echo "[]"
    fi
}

# Read JSON-RPC requests from stdin, respond on stdout
while IFS= read -r line; do
    method=$(echo "$line" | jq -r '.method // empty')
    id=$(echo "$line" | jq -r '.id // empty')

    case "$method" in
        "initialize")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"project-info","version":"1.0.0"}}}'
            ;;
        "tools/list")
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"tools":[{"name":"project_structure","description":"List project files (max depth 3, max 100 files)","inputSchema":{"type":"object","properties":{"depth":{"type":"number","default":3}}}},{"name":"file_summary","description":"Show line count and first lines of a file","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"lines":{"type":"number","default":5}},"required":["path"]}},{"name":"search_code","description":"Search for a pattern across source files","inputSchema":{"type":"object","properties":{"pattern":{"type":"string"},"glob":{"type":"string","default":"*"}},"required":["pattern"]}},{"name":"project_list","description":"Discover available projects in ~/src/ (git repos)","inputSchema":{"type":"object","properties":{}}},{"name":"sibling_projects","description":"Discover sibling projects in parent directory","inputSchema":{"type":"object","properties":{"path":{"type":"string","default":"."}},"required":[]}},{"name":"project_info","description":"Get detailed info about a project at a path","inputSchema":{"type":"object","properties":{"path":{"type":"string","default":"."}},"required":[]}},{"name":"project_type","description":"Detect project type from marker files","inputSchema":{"type":"object","properties":{"path":{"type":"string","default":"."}},"required":[]}},{"name":"project_metadata","description":"Get structured metadata about a project","inputSchema":{"type":"object","properties":{"path":{"type":"string","default":"."},"name":{"type":"string"}},"required":[]}}]}}'
            ;;
        "tools/call")
            tool=$(echo "$line" | jq -r '.params.name')
            args=$(echo "$line" | jq -r '.params.arguments // {}')
            case "$tool" in
                "project_structure")
                    depth=$(echo "$args" | jq -r '.depth // 3')
                    result=$(find . -maxdepth "$depth" -type f 2>&1 | head -100 || echo "Failed to list files")
                    ;;
                "file_summary")
                    filepath=$(echo "$args" | jq -r '.path')
                    lines=$(echo "$args" | jq -r '.lines // 5')
                    if [ -f "$filepath" ]; then
                        line_count=$(wc -l < "$filepath")
                        preview=$(head -n "$lines" "$filepath")
                        result="Lines: ${line_count}
--- first ${lines} lines ---
${preview}"
                    else
                        result="File not found: $filepath"
                    fi
                    ;;
                "search_code")
                    pattern=$(echo "$args" | jq -r '.pattern')
                    file_glob=$(echo "$args" | jq -r '.glob // "*"')
                    result=$(grep -rn "$pattern" --include="$file_glob" . 2>&1 | head -50 || echo "No matches found")
                    ;;
                "project_list")
                    # @trace spec:forge-environment-discoverability
                    # Discover projects in ~/src/ by scanning for .git/ directories
                    # Return JSON array of projects with metadata
                    project_data="[]"
                    if [ -d "$HOME/src" ]; then
                        projects_json=""
                        for project_dir in "$HOME/src"/*; do
                            if [ -d "$project_dir" ] && [ -d "$project_dir/.git" ]; then
                                project_name=$(basename "$project_dir")
                                description=""
                                # Try to extract first line of README as description
                                if [ -f "$project_dir/README.md" ]; then
                                    description=$(head -1 "$project_dir/README.md" | sed 's/^# //' | sed 's/^## //' | head -c 100)
                                fi
                                # Check if Tillandsias-managed
                                is_managed="false"
                                [ -f "$project_dir/.tillandsias/config.toml" ] && is_managed="true"

                                if [ -z "$projects_json" ]; then
                                    projects_json="{\"name\":\"$project_name\",\"description\":\"$description\",\"managed\":$is_managed}"
                                else
                                    projects_json="$projects_json,{\"name\":\"$project_name\",\"description\":\"$description\",\"managed\":$is_managed}"
                                fi
                            fi
                        done
                        [ -n "$projects_json" ] && project_data="[$projects_json]"
                    fi
                    result="$project_data"
                    ;;
                "sibling_projects")
                    # @trace gap:ON-006
                    # Discover sibling projects in the parent directory
                    path=$(echo "$args" | jq -r '.path // "."')
                    result=$(discover_sibling_projects "$path")
                    ;;
                "project_type")
                    # @trace spec:forge-environment-discoverability
                    # Detect project type from marker files
                    path=$(echo "$args" | jq -r '.path // "."')
                    result=$(detect_project_types "$path")
                    ;;
                "project_info")
                    # @trace spec:forge-environment-discoverability
                    # Get detailed project info (deprecated in favor of project_metadata)
                    path=$(echo "$args" | jq -r '.path // "."')
                    result=$(get_project_metadata "$path")
                    ;;
                "project_metadata")
                    # @trace spec:forge-environment-discoverability
                    # Get structured metadata about a project
                    path=$(echo "$args" | jq -r '.path // "."')
                    name=$(echo "$args" | jq -r '.name // "unknown"')
                    result=$(get_project_metadata "$path" "$name")
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
            # MCP spec: respond to prompts/list even when no prompts exist.
            # Silence here hangs OpenCode's /command endpoint for 60s.
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
            # Respond to unknown methods with MCP's "method not found" error
            # so OpenCode doesn't stall 60s waiting for a reply that never
            # comes.
            if [ -n "$id" ]; then
                echo '{"jsonrpc":"2.0","id":"'"$id"'","error":{"code":-32601,"message":"Method not found: '"$method"'"}}'
            fi
            ;;
    esac
done
