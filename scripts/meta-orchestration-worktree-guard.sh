#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 snapshot|verify STATE_DIR" >&2
    exit 2
}

hash_path() {
    local path="$1"
    if [[ -L "$path" ]]; then
        printf 'symlink:'
        readlink "$path" | git hash-object --stdin
    elif [[ -f "$path" ]]; then
        printf 'file:'
        git hash-object --no-filters -- "$path"
    elif [[ -d "$path" ]]; then
        echo "error: dirty directory/submodule is unsupported: $path" >&2
        return 2
    elif [[ ! -e "$path" && ! -L "$path" ]]; then
        printf 'missing\n'
    else
        echo "error: dirty special file is unsupported: $path" >&2
        return 2
    fi
}

capture() {
    local destination="$1" path
    git status --porcelain=v1 -z --untracked-files=all >"$destination/status.z"
    git diff --binary >"$destination/worktree.diff"
    git diff --cached --binary >"$destination/index.diff"
    {
        git diff --name-only -z
        git diff --cached --name-only -z
        git ls-files --others --exclude-standard -z
    } >"$destination/paths.z"
    : >"$destination/hashes"
    while IFS= read -r -d '' path; do
        hash_path "$path" >>"$destination/hashes"
    done <"$destination/paths.z"
}

load_state() {
    [[ $# -eq 1 ]] || usage
    state_dir="$(cd "$1" 2>/dev/null && pwd -P)" || {
        echo "error: state directory does not exist: $1" >&2
        exit 2
    }
    [[ -f "$state_dir/repo-root" && -f "$state_dir/startup/status.z" ]] || {
        echo "error: invalid boundary state: $state_dir" >&2
        exit 2
    }
    repo_root="$(cat "$state_dir/repo-root")"
    cd "$repo_root"
}

mode="${1:-}"
shift || true

case "$mode" in
    snapshot)
        [[ $# -eq 1 ]] || usage
        repo_root="$(cd "$(git rev-parse --show-toplevel)" && pwd -P)"
        mkdir -p "$1"
        state_dir="$(cd "$1" && pwd -P)"
        case "$state_dir/" in
            "$repo_root/"*)
                echo "error: boundary state must live outside the worktree" >&2
                exit 2
                ;;
        esac
        [[ ! -e "$state_dir/startup" && ! -e "$state_dir/repo-root" ]] || {
            echo "error: boundary state already initialized: $state_dir" >&2
            exit 2
        }
        mkdir -p "$state_dir/startup" "$state_dir/tmp"
        printf '%s\n' "$repo_root" >"$state_dir/repo-root"
        cd "$repo_root"
        capture "$state_dir/startup"
        ;;
    verify)
        load_state "$@"
        current="$state_dir/current"
        rm -rf "$current"
        mkdir -p "$current"
        capture "$current"
        cmp "$state_dir/startup/status.z" "$current/status.z" >/dev/null &&
            cmp "$state_dir/startup/paths.z" "$current/paths.z" >/dev/null &&
            cmp "$state_dir/startup/hashes" "$current/hashes" >/dev/null &&
            cmp "$state_dir/startup/worktree.diff" "$current/worktree.diff" >/dev/null &&
            cmp "$state_dir/startup/index.diff" "$current/index.diff" >/dev/null || {
                echo "error: worktree differs from startup boundary" >&2
                exit 1
            }
        echo "ok: startup worktree boundary preserved"
        ;;
    *) usage ;;
esac
