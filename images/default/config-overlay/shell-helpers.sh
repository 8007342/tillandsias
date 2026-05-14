#!/usr/bin/env bash
# @trace spec:forge-shell-tools, spec:forge-environment-discoverability
# Shell helper functions for Tillandsias forge container
# Source this file from bashrc, zshrc, or config.fish

# ls-projects: List available projects in ~/src/ with descriptions
ls-projects() {
    # @trace spec:forge-environment-discoverability
    if [ ! -d "$HOME/src" ]; then
        echo "No projects found (~/src does not exist)" >&2
        return 1
    fi

    printf '%s\n' "Available projects in ~/src/:"
    printf '\n'
    printf '%-30s %-50s %s\n' "Project" "Description" "Managed"
    printf '%s\n' "$(printf -- '-%.0s' {1..90})"

    for project_dir in "$HOME/src"/*; do
        if [ -d "$project_dir" ] && [ -d "$project_dir/.git" ]; then
            project_name=$(basename "$project_dir")
            description=""
            if [ -f "$project_dir/README.md" ]; then
                description=$(head -1 "$project_dir/README.md" | sed 's/^# //' | sed 's/^## //' | cut -c1-50)
            fi
            is_managed="✗"
            [ -f "$project_dir/.tillandsias/config.toml" ] && is_managed="✓"
            printf '%-30s %-50s %s\n' "$project_name" "$description" "$is_managed"
        fi
    done
}

# clone-fresh: Clone a project from git mirror (offline mode)
clone-fresh() {
    # @trace spec:forge-environment-discoverability, spec:git-mirror-service
    local project="$1"
    if [ -z "$project" ]; then
        echo "Usage: clone-fresh <project-name>" >&2
        return 1
    fi

    local git_service="${GIT_SERVICE_HOST:-git-service}"
    local git_port="${GIT_SERVICE_PORT:-9418}"

    echo "Cloning $project from git://$git_service/$project ..."
    git clone "git://$git_service/$project" "$HOME/src/$project" || {
        echo "Failed to clone $project from git service" >&2
        return 1
    }
    echo "✓ Cloned $project to ~/src/$project"
}

# git-status-all: Show status of all projects
git-status-all() {
    # @trace spec:forge-environment-discoverability, spec:git-mirror-service
    if [ ! -d "$HOME/src" ]; then
        echo "No projects found" >&2
        return 1
    fi

    for project_dir in "$HOME/src"/*; do
        if [ -d "$project_dir" ] && [ -d "$project_dir/.git" ]; then
            project_name=$(basename "$project_dir")
            status_out=$(cd "$project_dir" && git status --short 2>&1)
            if [ -n "$status_out" ]; then
                echo "$project_name:"
                echo "$status_out" | sed 's/^/  /'
                echo ""
            fi
        fi
    done
}

# cheatsheet: Search cheatsheets by topic
cheatsheet() {
    # @trace spec:agent-cheatsheets, spec:forge-environment-discoverability
    local topic="$1"
    local cheatsheets_dir="${TILLANDSIAS_CHEATSHEETS:-/opt/cheatsheets}"

    if [ -z "$topic" ]; then
        echo "Usage: cheatsheet <topic>" >&2
        echo "Available cheatsheets:" >&2
        if [ -f "$cheatsheets_dir/INDEX.md" ]; then
            grep -E "^## |^- " "$cheatsheets_dir/INDEX.md" 2>/dev/null || {
                echo "  (run: cat $cheatsheets_dir/INDEX.md to browse)" >&2
            }
        else
            echo "  (cheatsheets not found at $cheatsheets_dir)" >&2
        fi
        return 1
    fi

    if [ ! -d "$cheatsheets_dir" ]; then
        echo "Cheatsheets directory not found: $cheatsheets_dir" >&2
        return 1
    fi

    # Try to find and display matching cheatsheet
    if command -v rg >/dev/null 2>&1; then
        rg -l "$topic" "$cheatsheets_dir" 2>/dev/null | head -5
    elif command -v grep >/dev/null 2>&1; then
        grep -r -l "$topic" "$cheatsheets_dir" 2>/dev/null | head -5
    else
        echo "No search tool available (rg or grep)" >&2
        return 1
    fi
}

# Helper: Show all available shell helper functions
tillandsias-shell-help() {
    # @trace spec:forge-shell-tools
    cat <<'EOF'
Tillandsias shell helpers:

  ls-projects          List all projects in ~/src/ with descriptions
  clone-fresh <proj>   Clone a project from the git mirror (offline)
  git-status-all       Show git status for all projects
  cheatsheet <topic>   Search cheatsheets for a topic
  tillandsias-help     Show this help message

Discovery commands (for full details):
  tillandsias-inventory [--json]   List installed toolchains
  tillandsias-services [--json]    List enclave services
  tillandsias-models [--json]      List inference models

For more info, see:
  cat $TILLANDSIAS_CHEATSHEETS/INDEX.md | rg <topic>
EOF
}

# Alias for consistency
alias tillandsias-help=tillandsias-shell-help
