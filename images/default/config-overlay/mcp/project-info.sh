#!/usr/bin/env bash
# MCP Server: Project Info for Tillandsias forge containers
# @trace spec:layered-tools-overlay, spec:forge-environment-discoverability
# Communicates via JSON-RPC over stdin/stdout (MCP stdio transport)
#
# Tools: project_structure, file_summary, search_code, project_list, project_info,
#        project_type, project_metadata, find_files, grep_code, git_status,
#        read_file, plan_query

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
    # @trace spec:forge-environment-discoverability, gap:multi-workdir-git-worktree-handling
    # Use [ -e ] instead of [ -d ] to support git worktrees, which have .git as a file (pointing to parent worktree) not a directory
    [ -e "$project_dir/.git" ] && types="$types git"

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
            # @trace spec:forge-environment-discoverability, gap:multi-workdir-git-worktree-handling
            # Use [ -e ] instead of [ -d ] to support git worktrees, which have .git as a file
            if [ ! -d "$project_dir" ] || [ ! -e "$project_dir/.git" ]; then
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
            echo '{"jsonrpc":"2.0","id":"'"$id"'","result":{"tools":[{"name":"project_structure","description":"List project files (max depth 3, max 100 files)","inputSchema":{"type":"object","properties":{"depth":{"type":"number","default":3}}}},{"name":"file_summary","description":"Show line count and first lines of a file","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"lines":{"type":"number","default":5}},"required":["path"]}},{"name":"search_code","description":"Search for a pattern across source files (glob supports path patterns)","inputSchema":{"type":"object","properties":{"pattern":{"type":"string"},"glob":{"type":"string","default":"*"}},"required":["pattern"]}},{"name":"find_files","description":"Find files by glob pattern (recursive, path-aware)","inputSchema":{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern e.g. **/*.sh, plan/index.yaml"},"path":{"type":"string","description":"Root directory (default: .)"}},"required":["pattern"]}},{"name":"grep_code","description":"Search for a pattern across source files with path-aware glob","inputSchema":{"type":"object","properties":{"pattern":{"type":"string"},"include":{"type":"string","description":"File glob pattern (default: *)"},"path":{"type":"string","description":"Root directory (default: .)"}},"required":["pattern"]}},{"name":"git_status","description":"Show working tree status as structured JSON data","inputSchema":{"type":"object","properties":{}}},{"name":"read_file","description":"Read a file with offset and limit support","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"number","description":"Line number to start from (1-indexed, default: 0 for beginning)"},"limit":{"type":"number","description":"Number of lines to read (default: all)"}},"required":["path"]}},{"name":"plan_query","description":"Query plan/index.yaml for matching work packets by status, role, or capability tags","inputSchema":{"type":"object","properties":{"status":{"type":"string","description":"Filter by status (ready, pending, in_progress, blocked, completed, etc.)"},"pickup_role":{"type":"string","description":"Filter by pickup_role substring"},"capability_tags":{"type":"array","items":{"type":"string"},"description":"Filter by capability tags (all must match)"},"limit":{"type":"number","description":"Max results (default: 20)"}}}},{"name":"project_list","description":"Discover available projects in ~/src/ (git repos)","inputSchema":{"type":"object","properties":{}}},{"name":"sibling_projects","description":"Discover sibling projects in parent directory","inputSchema":{"type":"object","properties":{"path":{"type":"string","default":"."}},"required":[]}},{"name":"project_info","description":"Get detailed info about a project at a path","inputSchema":{"type":"object","properties":{"path":{"type":"string","default":"."}},"required":[]}},{"name":"project_type","description":"Detect project type from marker files","inputSchema":{"type":"object","properties":{"path":{"type":"string","default":"."}},"required":[]}},{"name":"project_metadata","description":"Get structured metadata about a project","inputSchema":{"type":"object","properties":{"path":{"type":"string","default":"."},"name":{"type":"string"}},"required":[]}}]}}'
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
                    # Use find + grep for path-aware glob matching (fixes Bug 1)
                    # Only strip **/ prefix when pattern starts with **/ (not a path)
                    if [[ "$file_glob" == "**/"* ]]; then
                        glob_for_find="${file_glob#**/}"
                    else
                        glob_for_find="$file_glob"
                    fi
                    # Capping the FILE list produced SILENT FALSE NEGATIVES. `find`
                    # emits in readdir order, not sorted, and that order shifts as
                    # the tree is written to. With `head -200` against 260 matching
                    # .sh files, ~60 were dropped ARBITRARILY and differently on
                    # each call — so `search_code(pattern, glob="*.sh")` reported
                    # "No matches found" for a pattern that is plainly in
                    # ./build.sh (find position 14; the captured list happened to
                    # start at position 15). A search tool that says "not found"
                    # for something present is worse than no search tool: the agent
                    # concludes the code does not exist and acts on it.
                    #
                    # Search EVERY matching file. Cap the RESULTS instead, and say
                    # so when the cap is hit, so truncation is never mistaken for
                    # absence.
                    # || true prevents set -e killing the script on SIGPIPE.
                    if [[ "$glob_for_find" == *"/"* ]]; then
                        files=$(find . -type f -path "*/$glob_for_find" 2>/dev/null || true)
                    else
                        files=$(find . -type f -name "$glob_for_find" 2>/dev/null || true)
                    fi
                    if [ -n "$files" ]; then
                        all_hits=$(echo "$files" | xargs grep -In "$pattern" 2>/dev/null || true)
                        hit_count=$(printf '%s' "$all_hits" | grep -c . || true)
                        result=$(printf '%s' "$all_hits" | head -50 || true)
                        if [ "${hit_count:-0}" -gt 50 ]; then
                            result="${result}
[truncated: showing 50 of ${hit_count} matches — narrow the glob or pattern to see the rest]"
                        fi
                    fi
                    if [ -z "${result:-}" ]; then
                        result="No matches found"
                    fi
                    ;;
                "project_list")
                    # @trace spec:forge-environment-discoverability, gap:multi-workdir-git-worktree-handling
                    # Discover projects in ~/src/ by scanning for .git/ directories or .git files (for git worktrees)
                    # Return JSON array of projects with metadata
                    project_data="[]"
                    if [ -d "$HOME/src" ]; then
                        projects_json=""
                        for project_dir in "$HOME/src"/*; do
                            # Use [ -e ] instead of [ -d ] to support git worktrees, which have .git as a file
                            if [ -d "$project_dir" ] && [ -e "$project_dir/.git" ]; then
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
                "find_files")
                    pattern=$(echo "$args" | jq -r '.pattern')
                    path=$(echo "$args" | jq -r '.path // "."')
                    if [[ "$pattern" == "**/"* ]]; then
                        find_pattern="${pattern#**/}"
                    else
                        find_pattern="$pattern"
                    fi
                    # || true prevents set -e from killing script on SIGPIPE
                    if [[ "$find_pattern" == *"/"* ]]; then
                        result=$(find "$path" -type f -path "*/$find_pattern" 2>/dev/null | head -200 || true)
                    else
                        result=$(find "$path" -type f -name "$find_pattern" 2>/dev/null | head -200 || true)
                    fi
                    if [ -z "${result:-}" ]; then
                        result="No files found"
                    fi
                    ;;
                "grep_code")
                    pattern=$(echo "$args" | jq -r '.pattern')
                    include=$(echo "$args" | jq -r '.include // "*"')
                    path=$(echo "$args" | jq -r '.path // "."')
                    if [[ "$include" == "**/"* ]]; then
                        glob_for_find="${include#**/}"
                    else
                        glob_for_find="$include"
                    fi
                    # || true prevents set -e from killing script on SIGPIPE
                    if [[ "$glob_for_find" == *"/"* ]]; then
                        files=$(find "$path" -type f -path "*/$glob_for_find" 2>/dev/null | head -200 || true)
                    else
                        files=$(find "$path" -type f -name "$glob_for_find" 2>/dev/null | head -200 || true)
                    fi
                    if [ -n "$files" ]; then
                        result=$(echo "$files" | xargs grep -In "$pattern" 2>/dev/null | head -50 || true)
                    fi
                    if [ -z "${result:-}" ]; then
                        result="No matches found"
                    fi
                    ;;
                "git_status")
                    porcelain=$(git status --porcelain 2>/dev/null) || porcelain=""
                    if [ -z "$porcelain" ]; then
                        if [ -e ".git" ]; then
                            result='{"files":[],"porcelain":""}'
                        else
                            result='{"error":"not a git repository or git not available"}'
                        fi
                    else
                        # Rewritten from python3 (tlatoani_hard_no_python). jq is present in the forge
# image; ruby is NOT, so jq is the correct tool here rather than the host's.
                        result=$(printf '%s\n' "$porcelain" | awk 'NF {
                            staged = substr($0, 1, 1);
                            working = substr($0, 2, 1);
                            path = substr($0, 4);
                            print staged "\t" working "\t" path;
                        }' | jq -R -s '
                            [ split("\n")[] | select(length > 0) | split("\t")
                              | { staged_status: .[0], working_status: .[1], path: .[2] }
                              | if (.path | test(" -> ")) then
                                    (.path | split(" -> ")) as $p
                                    | { path: $p[0], new_path: $p[1],
                                        staged_status: .staged_status,
                                        working_status: .working_status }
                                else . end
                            ] | { files: . }')
                    fi
                    ;;
                "read_file")
                    filepath=$(echo "$args" | jq -r '.path')
                    offset=$(echo "$args" | jq -r '.offset // 0')
                    limit=$(echo "$args" | jq -r '.limit // 0')
                    if [ ! -f "$filepath" ]; then
                        result="File not found: $filepath"
                    else
                        line_count=$(wc -l < "$filepath")
                        if [ "$offset" -gt 0 ] && [ "$limit" -gt 0 ]; then
                            result=$(tail -n +"$offset" "$filepath" | head -n "$limit")
                            result="${result}
---
(offset=$offset limit=$limit of $line_count lines)"
                        elif [ "$offset" -gt 0 ]; then
                            result=$(tail -n +"$offset" "$filepath")
                            result="${result}
---
(offset=$offset of $line_count lines)"
                        elif [ "$limit" -gt 0 ]; then
                            result=$(head -n "$limit" "$filepath")
                            result="${result}
---
(limit=$limit of $line_count lines)"
                        else
                            result=$(cat "$filepath")
                            result="${result}
---
($line_count lines total)"
                        fi
                    fi
                    ;;
                "plan_query")
                    filter_args=$(echo "$args" | jq -c '.')
                    # Rewritten from python3 (tlatoani_hard_no_python). yq v4 is present in the
# forge image and reads the ledger natively, so this no longer hand-parses YAML.
                        result=$(yq -o=json '
                            [ .plan_index.steps[]
                              | pick(["packet_id","order","title","status","kind","pickup_role","capability_tags","deliverable","depends_on"]) ]
                        ' plan/index.yaml 2>/dev/null | jq --argjson f "$filter_args" '
                            [ .[]
                              | select(($f.status // null) == null or .status == $f.status)
                              | select(($f.pickup_role // null) == null or ((.pickup_role // "") | ascii_downcase | contains($f.pickup_role | ascii_downcase)))
                              | select(($f.capability_tags // null) == null or (((.capability_tags // []) - $f.capability_tags) | length) == ((.capability_tags // []) | length) - ($f.capability_tags | length))
                            ] | .[0:(($f.limit // 20) | tonumber)]')
                    if [ -z "$result" ]; then
                        result="No matching packets found"
                    fi
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
