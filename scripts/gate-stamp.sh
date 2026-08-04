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
    # Hash the CONTENT of every tracked and untracked file in the worktree.
    #
    # This deliberately ignores HEAD and the index. An earlier version hashed
    # `HEAD + git diff HEAD`, which was wrong in a way that made the gate
    # unusable: committing changes HEAD without changing a single byte of
    # content, so the stamp went stale at exactly the moment you push. `git add`
    # broke it the same way. The property we actually want is "the gate
    # validated these bytes", and bytes do not care which commit they are on.
    #
    # So: staging is invisible, committing is invisible, editing is not. A
    # deleted file drops its line and therefore changes the stamp, which is
    # correct. The path list is folded in explicitly so a deletion cannot be
    # confused with an unreadable file.
    #
    # Cost is ~60ms over ~4000 files — cheap enough that the hook can do this on
    # every push, which is the whole reason the stamp exists instead of re-running
    # the multi-minute gate.
    # Hash path, filesystem type, and content as NUL-framed records. A plain
    # `sha256sum <path>` follows symlinks; Tillandsias deliberately tracks the
    # runtime skill entries as symlinks to directories, so that implementation
    # failed every real checkout with "Is a directory" and never wrote a stamp.
    # Hash the link target text instead. Refuse any other non-file entry rather
    # than silently claiming that an unmeasured tree was validated.
    git -C "$REPO_ROOT" ls-files -z --cached --others --exclude-standard 2>/dev/null \
        | LC_ALL=C sort -z \
        | while IFS= read -r -d '' path; do
            absolute="$REPO_ROOT/$path"
            if [[ -L "$absolute" ]]; then
                digest="$(readlink "$absolute" | sha256sum | cut -d' ' -f1)" || exit 1
                printf 'symlink\0%s\0%s\0' "$path" "$digest"
            elif [[ -f "$absolute" ]]; then
                digest="$(sha256sum "$absolute" | cut -d' ' -f1)" || exit 1
                printf 'file\0%s\0%s\0' "$path" "$digest"
            else
                echo "gate-stamp: unsupported worktree entry: $path" >&2
                exit 1
            fi
        done \
        | sha256sum | cut -d' ' -f1
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
