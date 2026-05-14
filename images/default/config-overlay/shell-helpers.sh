#!/usr/bin/env bash
# @trace spec:forge-shell-tools, spec:forge-environment-discoverability, spec:forge-cache-dual
# Shell helper functions for Tillandsias forge container
# Source this file from bashrc, zshrc, or config.fish
#
# Shortcuts (paired with MCP tools in config-overlay/mcp/git-tools.sh):
#   tgs           — tillandsias git status (mirror-aware short status)
#   tgp           — tillandsias git push via enclave mirror
#   tgpull        — tillandsias git pull (ff-only) via enclave mirror
#   cache-report  — per-tier cache size summary
#
# Discoverability:
#   tillandsias-help  shows every helper provided by this file.
# @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md

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

# switch-project: Quick-switch to a sibling project in the same workspace
# @trace gap:ON-006
# Usage: switch-project <project-name>
switch-project() {
    local target_project="${1:-}"

    if [ -z "$target_project" ]; then
        echo "Usage: switch-project <project-name>" >&2
        if [ "$TILLANDSIAS_WORKSPACE_COUNT" -gt 0 ]; then
            echo "" >&2
            echo "Available sibling projects:" >&2
            IFS=':' read -ra projects <<< "$TILLANDSIAS_SIBLING_PROJECTS"
            for proj in "${projects[@]}"; do
                echo "  • $proj" >&2
            done
        else
            echo "No sibling projects found." >&2
        fi
        return 1
    fi

    # Get the parent directory from current project path
    local parent_dir
    parent_dir=$(dirname "${TILLANDSIAS_PROJECT_PATH:-.}")

    # Check if the target project exists
    local target_path="$parent_dir/$target_project"
    if [ ! -d "$target_path" ] || [ ! -d "$target_path/.git" ]; then
        echo "ERROR: Project '$target_project' not found in $parent_dir" >&2
        return 1
    fi

    # Change to the target project directory
    cd "$target_path" || return 1
    echo "Switched to: $target_project"

    return 0
}

# list-projects: List available sibling projects (projects in same parent directory)
# @trace gap:ON-006
list-projects() {
    echo "Available projects in $(dirname "${TILLANDSIAS_PROJECT_PATH:-.}"):"
    if [ "$TILLANDSIAS_WORKSPACE_COUNT" -gt 0 ]; then
        IFS=':' read -ra projects <<< "$TILLANDSIAS_SIBLING_PROJECTS"
        for proj in "${projects[@]}"; do
            echo "  • $proj"
        done
    else
        echo "  (none)"
    fi
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

# tgs: tillandsias git status — short status against the enclave mirror.
# Shorthand for `git status --short`. Matches MCP tool `git_status`.
# @trace spec:forge-shell-tools, spec:git-mirror-service
tgs() {
    git status --short "$@"
}

# tgp: tillandsias git push — push the current branch through the enclave
# git mirror. Matches MCP tool `git_push`.
# Forge containers have no external network; pushes flow to the git-service
# container which re-pushes to GitHub using the host-keyring credentials.
# @trace spec:forge-shell-tools, spec:git-mirror-service
tgp() {
    local remote="${1:-origin}"
    local branch="${2:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')}"
    if [ -z "$branch" ]; then
        echo "tgp: not on any branch; cannot push" >&2
        return 1
    fi
    echo "tgp: pushing $branch -> $remote (via enclave mirror)" >&2
    git push "$remote" "$branch"
}

# tgpull: tillandsias git pull (fast-forward only). Matches MCP tool `git_pull`.
# @trace spec:forge-shell-tools, spec:git-mirror-service
tgpull() {
    local remote="${1:-origin}"
    local branch="${2:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')}"
    if [ -z "$branch" ]; then
        echo "tgpull: not on any branch; cannot pull" >&2
        return 1
    fi
    echo "tgpull: pulling $branch <- $remote (ff-only)" >&2
    git pull --ff-only "$remote" "$branch"
}

# cache-report: per-tier cache size summary.
# Matches MCP tool `cache_report`. Reads the Wave 7 cache constants
# (TILLANDSIAS_PROJECT_CACHE, TILLANDSIAS_SHARED_CACHE, TILLANDSIAS_EPHEMERAL,
# TILLANDSIAS_WORKSPACE) set by lib-common.sh.
# @trace spec:forge-shell-tools, spec:forge-cache-dual
cache-report() {
    local shared="${TILLANDSIAS_SHARED_CACHE:-/nix/store}"
    local project="${TILLANDSIAS_PROJECT_CACHE:-$HOME/.cache/tillandsias-project}"
    local workspace="${TILLANDSIAS_WORKSPACE:-$HOME/src}"
    local ephemeral="${TILLANDSIAS_EPHEMERAL:-/tmp}"

    printf '%s\n' "Tillandsias cache report:"
    printf '\n'
    printf '%-12s %-44s %-10s %s\n' "Tier" "Path" "Size" "Persists?"
    printf '%s\n' "$(printf -- '-%.0s' {1..90})"

    for entry in \
        "shared|$shared|yes (RO)" \
        "project|$project|yes" \
        "workspace|$workspace|yes (git)" \
        "ephemeral|$ephemeral|no"; do
        IFS='|' read -r tier path persists <<<"$entry"
        local size="—"
        if [ -d "$path" ]; then
            size=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
        fi
        printf '%-12s %-44s %-10s %s\n' "$tier" "$path" "$size" "$persists"
    done

    printf '\n'
    printf '%s\n' "Read more: \$TILLANDSIAS_CHEATSHEETS/runtime/forge-paths-ephemeral-vs-persistent.md"
}

# help: Display Tillandsias Forge help system
# Locale-aware: sources help-{es,fr,de,ja}.sh if available
# @trace spec:help-system-localization
help() {
    # Detect locale
    local locale_raw="${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}"
    local locale="${locale_raw%%_*}"
    locale="${locale%%.*}"

    # Try localized help script
    local help_script="/usr/local/share/tillandsias/help-${locale}.sh"
    if [ ! -f "$help_script" ]; then
        help_script="/usr/local/share/tillandsias/help.sh"
    fi

    if [ -f "$help_script" ]; then
        bash "$help_script" | ${PAGER:-less -R}
    else
        echo "Help system not found at $help_script" >&2
        return 1
    fi
}

# Helper: Show all available shell helper functions
tillandsias-shell-help() {
    # @trace spec:forge-shell-tools
    cat <<'EOF'
Tillandsias shell helpers:

  Project navigation:
    ls-projects          List all projects in ~/src/ with descriptions
    list-projects        List sibling projects in current workspace
    switch-project <p>   Switch to a sibling project
    clone-fresh <proj>   Clone a project from the git mirror (offline)
    git-status-all       Show git status for all projects
    cheatsheet <topic>   Search cheatsheets for a topic

  Git shortcuts (mirror-aware):
    tgs                  Short git status (= git status --short)
    tgp [remote] [br]    Push via enclave git mirror
    tgpull [remote] [br] Pull (ff-only) via enclave git mirror

  Cache discipline:
    cache-report         Summarize size of each cache tier
                         (shared / project / workspace / ephemeral)

  Discovery commands:
    help                             Display Tillandsias Forge help (locale-aware)
    tillandsias-inventory [--json]   List installed toolchains
    tillandsias-services [--json]    List enclave services
    tillandsias-models [--json]      List inference models
    tillandsias-help                 Show this message

For more info, see:
  cat $TILLANDSIAS_CHEATSHEETS/INDEX.md | rg <topic>
  cat $TILLANDSIAS_CHEATSHEETS/runtime/forge-paths-ephemeral-vs-persistent.md
EOF
}

# Alias for consistency
alias tillandsias-help=tillandsias-shell-help
