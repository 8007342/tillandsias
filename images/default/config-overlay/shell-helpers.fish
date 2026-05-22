# @trace spec:forge-shell-tools, spec:forge-environment-discoverability, spec:forge-cache-dual
# Native fish helpers for the Tillandsias forge container.
# Keep command names aligned with shell-helpers.sh so bash, zsh, and fish expose
# the same user-facing surface.
# @cheatsheet runtime/forge-paths-ephemeral-vs-persistent.md

function ls-projects --description "List available projects in ~/src/ with descriptions"
    # @trace spec:forge-environment-discoverability
    if not test -d "$HOME/src"
        echo "No projects found (~/src does not exist)" >&2
        return 1
    end

    printf '%s\n\n' "Available projects in ~/src/:"
    printf '%-30s %-50s %s\n' "Project" "Description" "Managed"
    string repeat -n 90 -

    for project_dir in "$HOME/src"/*
        if test -d "$project_dir"; and test -d "$project_dir/.git"
            set project_name (basename "$project_dir")
            set description ""
            if test -f "$project_dir/README.md"
                set description (head -1 "$project_dir/README.md" | sed 's/^# //' | sed 's/^## //' | cut -c1-50)
            end
            set is_managed "x"
            if test -f "$project_dir/.tillandsias/config.toml"
                set is_managed "yes"
            end
            printf '%-30s %-50s %s\n' "$project_name" "$description" "$is_managed"
        end
    end
end

function clone-fresh --description "Clone a project from the enclave git mirror"
    # @trace spec:forge-environment-discoverability, spec:git-mirror-service
    set project $argv[1]
    if test -z "$project"
        echo "Usage: clone-fresh <project-name>" >&2
        return 1
    end

    set git_service "$GIT_SERVICE_HOST"
    test -n "$git_service"; or set git_service git-service
    set git_port "$GIT_SERVICE_PORT"
    test -n "$git_port"; or set git_port 9418

    echo "Cloning $project from git://$git_service/$project ..."
    git clone "git://$git_service/$project" "$HOME/src/$project"; or begin
        echo "Failed to clone $project from git service" >&2
        return 1
    end
    echo "Cloned $project to ~/src/$project"
end

function git-status-all --description "Show git status for all projects"
    # @trace spec:forge-environment-discoverability, spec:git-mirror-service
    if not test -d "$HOME/src"
        echo "No projects found" >&2
        return 1
    end

    for project_dir in "$HOME/src"/*
        if test -d "$project_dir"; and test -d "$project_dir/.git"
            set project_name (basename "$project_dir")
            set status_out (cd "$project_dir"; and git status --short 2>&1)
            if test -n "$status_out"
                echo "$project_name:"
                printf '%s\n' $status_out | sed 's/^/  /'
                echo ""
            end
        end
    end
end

function __tillandsias_workspace_count
    set count 0
    if set -q TILLANDSIAS_WORKSPACE_COUNT
        set count "$TILLANDSIAS_WORKSPACE_COUNT"
    end
    echo "$count"
end

function __tillandsias_sibling_projects
    if set -q TILLANDSIAS_SIBLING_PROJECTS
        string split ':' -- "$TILLANDSIAS_SIBLING_PROJECTS"
    end
end

function switch-project --description "Switch to a sibling project"
    # @trace gap:ON-006
    set target_project $argv[1]

    if test -z "$target_project"
        echo "Usage: switch-project <project-name>" >&2
        set count (__tillandsias_workspace_count)
        if test "$count" -gt 0
            echo "" >&2
            echo "Available sibling projects:" >&2
            for proj in (__tillandsias_sibling_projects)
                echo "  - $proj" >&2
            end
        else
            echo "No sibling projects found." >&2
        end
        return 1
    end

    set project_path "."
    if set -q TILLANDSIAS_PROJECT_PATH
        set project_path "$TILLANDSIAS_PROJECT_PATH"
    end
    set parent_dir (dirname "$project_path")
    set target_path "$parent_dir/$target_project"

    if not test -d "$target_path"; or not test -d "$target_path/.git"
        echo "ERROR: Project '$target_project' not found in $parent_dir" >&2
        return 1
    end

    cd "$target_path"; or return 1
    echo "Switched to: $target_project"
end

function list-projects --description "List sibling projects in the current workspace"
    # @trace gap:ON-006
    set project_path "."
    if set -q TILLANDSIAS_PROJECT_PATH
        set project_path "$TILLANDSIAS_PROJECT_PATH"
    end
    echo "Available projects in "(dirname "$project_path")":"

    set count (__tillandsias_workspace_count)
    if test "$count" -gt 0
        for proj in (__tillandsias_sibling_projects)
            echo "  - $proj"
        end
    else
        echo "  (none)"
    end
end

function cheatsheet --description "Search cheatsheets by topic"
    # @trace spec:agent-cheatsheets, spec:forge-environment-discoverability
    set topic $argv[1]
    set cheatsheets_dir "$TILLANDSIAS_CHEATSHEETS"
    test -n "$cheatsheets_dir"; or set cheatsheets_dir /opt/cheatsheets

    if test -z "$topic"
        echo "Usage: cheatsheet <topic>" >&2
        echo "Available cheatsheets:" >&2
        if test -f "$cheatsheets_dir/INDEX.md"
            grep -E "^## |^- " "$cheatsheets_dir/INDEX.md" 2>/dev/null; or echo "  (run: cat $cheatsheets_dir/INDEX.md to browse)" >&2
        else
            echo "  (cheatsheets not found at $cheatsheets_dir)" >&2
        end
        return 1
    end

    if not test -d "$cheatsheets_dir"
        echo "Cheatsheets directory not found: $cheatsheets_dir" >&2
        return 1
    end

    if command -v rg >/dev/null 2>&1
        rg -l "$topic" "$cheatsheets_dir" 2>/dev/null | head -5
    else if command -v grep >/dev/null 2>&1
        grep -r -l "$topic" "$cheatsheets_dir" 2>/dev/null | head -5
    else
        echo "No search tool available (rg or grep)" >&2
        return 1
    end
end

function tgs --description "Short git status"
    # @trace spec:forge-shell-tools, spec:git-mirror-service
    git status --short $argv
end

function tgp --description "Push the current branch through the enclave mirror"
    # @trace spec:forge-shell-tools, spec:git-mirror-service
    set remote $argv[1]
    test -n "$remote"; or set remote origin
    set branch $argv[2]
    if test -z "$branch"
        set branch (git rev-parse --abbrev-ref HEAD 2>/dev/null)
    end
    if test -z "$branch"
        echo "tgp: not on any branch; cannot push" >&2
        return 1
    end
    echo "tgp: pushing $branch -> $remote (via enclave mirror)" >&2
    git push "$remote" "$branch"
end

function tgpull --description "Pull the current branch through the enclave mirror"
    # @trace spec:forge-shell-tools, spec:git-mirror-service
    set remote $argv[1]
    test -n "$remote"; or set remote origin
    set branch $argv[2]
    if test -z "$branch"
        set branch (git rev-parse --abbrev-ref HEAD 2>/dev/null)
    end
    if test -z "$branch"
        echo "tgpull: not on any branch; cannot pull" >&2
        return 1
    end
    echo "tgpull: pulling $branch <- $remote (ff-only)" >&2
    git pull --ff-only "$remote" "$branch"
end

function cache-report --description "Summarize cache tier sizes"
    # @trace spec:forge-shell-tools, spec:forge-cache-dual
    set shared "$TILLANDSIAS_SHARED_CACHE"
    test -n "$shared"; or set shared /nix/store
    set project "$TILLANDSIAS_PROJECT_CACHE"
    test -n "$project"; or set project "$HOME/.cache/tillandsias-project"
    set workspace "$TILLANDSIAS_WORKSPACE"
    test -n "$workspace"; or set workspace "$HOME/src"
    set ephemeral "$TILLANDSIAS_EPHEMERAL"
    test -n "$ephemeral"; or set ephemeral /tmp

    printf '%s\n\n' "Tillandsias cache report:"
    printf '%-12s %-44s %-10s %s\n' "Tier" "Path" "Size" "Persists?"
    string repeat -n 90 -

    for entry in \
        "shared|$shared|yes (RO)" \
        "project|$project|yes" \
        "workspace|$workspace|yes (git)" \
        "ephemeral|$ephemeral|no"
        set parts (string split '|' -- "$entry")
        set tier $parts[1]
        set path $parts[2]
        set persists $parts[3]
        set size "-"
        if test -d "$path"
            set size (du -sh "$path" 2>/dev/null | awk '{print $1}')
        end
        printf '%-12s %-44s %-10s %s\n' "$tier" "$path" "$size" "$persists"
    end

    printf '\n%s\n' 'Read more: $TILLANDSIAS_CHEATSHEETS/runtime/forge-paths-ephemeral-vs-persistent.md'
end

function help --description "Display Tillandsias Forge help"
    # @trace spec:help-system-localization
    set locale_raw en
    for candidate in LC_ALL LC_MESSAGES LANG
        if set -q $candidate
            set locale_raw $$candidate
            break
        end
    end
    set locale (string split -m1 '_' -- "$locale_raw")[1]
    set locale (string split -m1 '.' -- "$locale")[1]

    set help_script "/usr/local/share/tillandsias/help-$locale.sh"
    if not test -f "$help_script"
        set help_script /usr/local/share/tillandsias/help.sh
    end

    if test -f "$help_script"
        if command -v less >/dev/null 2>&1
            bash "$help_script" | less -R
        else
            bash "$help_script"
        end
    else
        echo "Help system not found at $help_script" >&2
        return 1
    end
end

function tillandsias-shell-help --description "Show Tillandsias shell helper commands"
    # @trace spec:forge-shell-tools
    printf '%s\n' \
        'Tillandsias shell helpers:' \
        '' \
        '  Project navigation:' \
        '    ls-projects          List all projects in ~/src/ with descriptions' \
        '    list-projects        List sibling projects in current workspace' \
        '    switch-project <p>   Switch to a sibling project' \
        '    clone-fresh <proj>   Clone a project from the git mirror (offline)' \
        '    git-status-all       Show git status for all projects' \
        '    cheatsheet <topic>   Search cheatsheets for a topic' \
        '' \
        '  Git shortcuts (mirror-aware):' \
        '    tgs                  Short git status (= git status --short)' \
        '    tgp [remote] [br]    Push via enclave git mirror' \
        '    tgpull [remote] [br] Pull (ff-only) via enclave git mirror' \
        '' \
        '  Cache discipline:' \
        '    cache-report         Summarize size of each cache tier' \
        '                         (shared / project / workspace / ephemeral)' \
        '' \
        '  Discovery commands:' \
        '    help                             Display Tillandsias Forge help (locale-aware)' \
        '    tillandsias-inventory [--json]   List installed toolchains' \
        '    tillandsias-services [--json]    List enclave services' \
        '    tillandsias-models [--json]      List inference models' \
        '    tillandsias-help                 Show this message' \
        '' \
        'For more info, see:' \
        '  cat $TILLANDSIAS_CHEATSHEETS/INDEX.md | rg <topic>' \
        '  cat $TILLANDSIAS_CHEATSHEETS/runtime/forge-paths-ephemeral-vs-persistent.md'
end

function tillandsias-help --description "Show Tillandsias shell helper commands"
    tillandsias-shell-help $argv
end
