#!/usr/bin/env bash
# @trace order:1255-s4im, order:1176-9vqn
#
# lib-freeze-paths.sh — the ONE definition of what a release freeze holds, and
# the reads every freeze consumer shares. Sourced by
# scripts/hooks/pre-push-local-gate.sh (the client-side refusal),
# scripts/release-freeze.sh (set/clear/status/audit), scripts/release-preflight.sh
# (refuses a breached cut) and scripts/land-queue.sh (holds code landings into a
# frozen branch). It used to live inside the hook alone, so any second consumer
# would have been a copy, and a copy of a path predicate drifts silently.
#
# bash 3.2-safe (macOS /bin/bash), no toolchain, no plan binary: the hosts
# that most need the freeze enforced are the ones without either (1255-s4im).
#
# The alias trees (.claude/, .gemini/, .codex/, .opencode/, .github/skills/)
# are deliberately NOT exempt: the freeze owner's decision on 1255-s4im,
# 2026-09-26. The pattern is anchored on purpose.

# <path> -> 0 when a freeze does not hold it.
_freeze_path_is_exempt() {
    case "$1" in
        plan/*|docs/*|skills/*|cheatsheets/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Bounded, so a hung network cannot hang the caller.
_freeze_t() {
    local s="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
    else "$@"; fi
}

# <remote> <branch> -> "<sha>\t<ref>" per live marker, oldest epoch first;
# empty when not frozen; non-zero when the remote could not be asked.
freeze_markers() {
    local out
    out="$(_freeze_t 10 git ls-remote "$1" "refs/tillandsias/freeze/$2/*" 2>/dev/null)" || return 1
    [ -n "$out" ] || return 0
    # The epoch is the last path component; sort on it numerically.
    printf '%s\n' "$out" | awk -F'\t' '{ n = split($2, p, "/"); print p[n] "\t" $0 }' \
        | sort -n | cut -f2-
}

# <from> <to> -> the paths changed between two commits that a freeze HOLDS,
# one per line (empty when the change is plan-only or there is none).
freeze_held_paths() {
    local p
    git diff --name-only --no-renames "$1" "$2" -- 2>/dev/null | while IFS= read -r p; do
        [ -n "$p" ] || continue
        _freeze_path_is_exempt "$p" || printf '%s\n' "$p"
    done
}
