#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 snapshot|re-snapshot|verify STATE_DIR" >&2
    exit 2
}

# Cycle-scoped stamps, kept in the git dir so they are per-checkout, never
# committed, and reachable by a later step that was not told the state dir
# (order 717-3bvv). `boundary-state` records WHICH state dir this cycle
# snapshotted; `boundary-verified` records the HEAD that a successful verify
# observed. Together they answer the question the guard could not answer
# before: was a boundary recorded and verified for THIS cycle?
stamp_path() {
    local git_dir
    git_dir="$(git rev-parse --git-dir 2>/dev/null)" || return 1
    printf '%s/%s\n' "$git_dir" "$1"
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
        # NAME THE PROCESS FAULT, do not describe the symptom (order 717-3bvv).
        #
        # A cycle that never ran `snapshot` used to arrive here and read
        # "state directory does not exist: /tmp/…Wxg6hS" — the path from the
        # PREVIOUS cycle, already removed on its own successful exit. An agent
        # who reads that as a stale temp path is reading it correctly, and the
        # guard goes silent about the worktree precisely when the tree is dirty
        # and the stakes are highest. So distinguish the two cases by the
        # cycle-scoped stamp rather than by the directory's absence.
        local stamp
        stamp="$(stamp_path boundary-state 2>/dev/null || true)"
        if [[ -z "$stamp" || ! -f "$stamp" ]]; then
            echo "blocked:no-snapshot-taken"
            exit 3
        fi
        echo "blocked:boundary-state-missing:$(cat "$stamp")"
        exit 3
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
        # RETIRE THE PREVIOUS CYCLE'S BOUNDARY HERE, not at the end of the
        # cycle that created it (order 725-bu54).
        #
        # Finalization used to remove the state dir on its way out, which
        # treated its first completion as THE end of the cycle. An
        # operator-driven loop does not have one exit: the cycle continues
        # whenever the operator asks for more, and the second Finalization then
        # found its own boundary gone and could not attest. That happened twice
        # in one night, and cost a valid marker.
        #
        # Retiring at the START of the NEXT cycle fixes it without weakening
        # what 717-3bvv guarantees. The boundary being verified is still the
        # one taken BEFORE any work — re-verification after more commits
        # compares against cycle start, which is strictly what the guard is
        # for. The alternative, re-snapshotting when the tree looks clean, is
        # exactly the "snapshot at the end and call it a startup boundary" move
        # that guarantee exists to forbid.
        #
        # It also matches the project's stated posture: everything safe to
        # destroy and relaunch, with cleanup owned by the next start rather
        # than by a previous exit that may never come.
        previous_stamp="$(stamp_path boundary-state)"
        if [[ -f "$previous_stamp" ]]; then
            previous_dir="$(cat "$previous_stamp")"
            # Remove ONLY a path this guard recorded, that still looks like a
            # boundary, and that lives outside the worktree. A stale or edited
            # stamp must not become an arbitrary rm -rf.
            if [[ -n "$previous_dir" && "$previous_dir" != "$state_dir" \
                && -f "$previous_dir/repo-root" && -d "$previous_dir/startup" ]]; then
                case "$previous_dir/" in
                    "$repo_root/"*) : ;;   # never inside the worktree
                    *) rm -rf "$previous_dir" ;;
                esac
            fi
        fi

        # Open the cycle's boundary: record where it lives and clear any
        # verification left by the previous cycle, so a stale stamp can never
        # satisfy this one.
        printf '%s\n' "$state_dir" >"$(stamp_path boundary-state)"
        rm -f "$(stamp_path boundary-verified)"
        ;;
    re-snapshot)
        # Re-anchor the boundary after an intentional commit of launch-generated
        # opsx/openspec dirt (order 540). Sole caller: meta-orchestration after
        # scripts/check-opsx-generated-dirt.sh returned ok: and the cycle merged
        # the generated set as a chore(opsx): commit. Anything NOT in the
        # generated set must have been refused earlier, so re-anchoring here is
        # safe only when the caller proved the prior dirty set was opsx-only.
        load_state "$@"
        mkdir -p "$state_dir/tmp"
        capture "$state_dir/startup"
        echo "ok: startup boundary re-anchored"
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
        # Record WHICH head this verification observed. mo-full-attest.sh reads
        # it and refuses to print a marker unless it names the HEAD being
        # attested, so a verification from an earlier cycle — or from before the
        # cycle's own commits — cannot stand in for this one.
        git rev-parse HEAD >"$(stamp_path boundary-verified)" 2>/dev/null || true
        echo "ok: startup worktree boundary preserved"
        ;;
    *) usage ;;
esac
