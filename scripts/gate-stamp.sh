#!/usr/bin/env bash
# gate-stamp.sh — record and verify that the local gate ran against THIS tree.
# @trace spec:methodology-accountability
#
# WHY
#
# Push CI was removed on 2026-08-03 (operator directive: only the release may
# consume cloud minutes). `./build.sh --check` is now the only thing standing
# between an agent and a broken trunk — and within hours of the removal a
# sibling landed an always-true clippy expression on linux-next, because nothing
# required the gate to have been run.
#
# The obvious fix — run the whole gate inside the pre-push hook — fails in
# practice: a hook that takes minutes gets `--no-verify`'d on its second use,
# and then enforces nothing at all. So instead the gate STAMPS what it
# validated, and the hook verifies the stamp is current. Push-time cost is a
# hash of the diff; the guarantee is the same.
#
# WHAT THE STAMP COVERS
#
# HEAD plus the full working-tree diff against it, including untracked files.
# Any edit after the gate ran invalidates the stamp. This is deliberately strict:
# "I ran --check ten commits ago" is exactly the state that lets a regression
# through.
#
# The stamp lives in the git dir, never in the worktree — it is local machine
# state, not project content, and must never be committed or merged.
#
# SUBCOMMANDS
#   compute  print the stamp for the current tree
#   write    record the current stamp (call after the gate PASSES)
#   verify   ok:gate-fresh | stale:<reason>   (exit 0 / non-zero)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "stale:not-a-git-repo"
    exit 2
}
GIT_DIR="$(git rev-parse --absolute-git-dir 2>/dev/null)" || {
    echo "stale:no-git-dir"
    exit 2
}
STAMP_FILE="$GIT_DIR/tillandsias-gate-stamp"

compute() {
    # HEAD, the tracked diff, and the untracked file list. Hashing the diff
    # rather than the whole tree keeps this fast on a large checkout while still
    # catching every edit.
    {
        git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "no-head"
        git -C "$REPO_ROOT" diff HEAD 2>/dev/null
        git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all 2>/dev/null
    } | sha256sum | cut -d' ' -f1
}

case "${1:-verify}" in
    compute)
        compute
        ;;
    write)
        compute > "$STAMP_FILE" || {
            echo "stale:cannot-write-stamp"
            exit 1
        }
        echo "ok:gate-stamped"
        ;;
    verify)
        if [[ ! -f "$STAMP_FILE" ]]; then
            echo "stale:never-run"
            exit 1
        fi
        recorded="$(cat "$STAMP_FILE" 2>/dev/null)"
        current="$(compute)"
        if [[ -z "$recorded" ]]; then
            echo "stale:empty-stamp"
            exit 1
        fi
        if [[ "$recorded" != "$current" ]]; then
            echo "stale:tree-changed-since-gate"
            exit 1
        fi
        echo "ok:gate-fresh"
        ;;
    *)
        echo "usage: gate-stamp.sh [compute|write|verify]" >&2
        exit 2
        ;;
esac
