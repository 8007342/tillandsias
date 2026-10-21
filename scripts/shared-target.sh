#!/usr/bin/env bash
# @trace order:1807-shtg
#
# shared-target.sh — ONE canonical CARGO_TARGET_DIR for every worktree of a
# repository, made safe to share. Source it, then call `shared_target_enter ROOT`.
#
# WHY ONE DIRECTORY. sccache's Rust key includes the absolute target dir, so
# per-worktree targets measured 0 cross-worktree hits (1804-sccl). The
# canonical dir is <main checkout>/target — on the operator's hosts a bind
# mount of the RAID — so the key is the same for every worktree (and, with the
# same layout, every host: 1806-lanc).
#
# THE HAZARD IT MUST NOT REINTRODUCE (1590-j20f, 1599-egzz). Cargo judges a
# path package fresh by mtime alone and records nothing about which checkout
# built the output, so with one target a gate in worktree B can run worktree
# A's binaries, and env!("CARGO_MANIFEST_DIR") bakes A's path. Two guards:
#   1. LOCK  flock on <target>/.shared-target.lock, held for the life of the
#            calling process (fd 9), so two checkouts never build or test in
#            the directory at once. The wait is bounded; a refusal names the
#            holder from the owner record.
#   2. OWNER <target>/.shared-target-owner records "<checkout> <index digest>"
#            of the last builder. When it differs from this entry, every
#            tracked file here is touched (cargo then rebuilds each workspace
#            unit from THIS checkout's bytes; registry units stay cached) and
#            the record is rewritten. Same checkout + same index: no touch.
# Opt out: TILLANDSIAS_SHARED_TARGET=off. A caller-set CARGO_TARGET_DIR other
# than the canonical dir is respected untouched (the toolbox's own).

shared_target_canon() { # ROOT -> absolute canonical target dir, or empty
    local root="$1" common
    common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
    [ -n "$common" ] || return 0
    printf '%s/target\n' "$(dirname "$common")"
}

shared_target_digest() { # ROOT -> digest of the checkout path and its index
    local root="$1"
    { printf '%s\n' "$root"; git -C "$root" ls-files -s; } | sha256sum | cut -d' ' -f1
}

shared_target_enter() { # ROOT ; exports CARGO_TARGET_DIR, takes the lock, touches on owner change
    local root canon owner digest prev wait
    root="$(cd "$1" && pwd)" || return 1
    if [ "${TILLANDSIAS_SHARED_TARGET:-}" = "off" ]; then
        echo "shared-target: off (TILLANDSIAS_SHARED_TARGET=off)" >&2; return 0
    fi
    canon="$(shared_target_canon "$root")"
    if [ -z "$canon" ] || [ ! -d "$canon" ]; then
        echo "shared-target: off (no canonical target dir for $root)" >&2; return 0
    fi
    if [ -n "${CARGO_TARGET_DIR:-}" ] && [ "$CARGO_TARGET_DIR" != "$canon" ]; then
        echo "shared-target: off (CARGO_TARGET_DIR already set to $CARGO_TARGET_DIR)" >&2; return 0
    fi
    command -v flock >/dev/null 2>&1 || { echo "shared-target: REFUSED, no flock on PATH to serialize the shared dir" >&2; return 1; }
    owner="$canon/.shared-target-owner"
    # NESTED ENTER (re-exec inside the toolbox, fixtures calling build.sh):
    # the holder exports TILLANDSIAS_SHARED_TARGET_HELD="<canon>|<root>|<pid>".
    # A child for the same canon and checkout whose holder is alive inherits
    # the lock instead of self-deadlocking on a fresh open of the lockfile.
    local held="${TILLANDSIAS_SHARED_TARGET_HELD:-}"
    if [ -n "$held" ]; then
        local h_canon h_root h_pid
        IFS='|' read -r h_canon h_root h_pid <<<"$held"
        if [ "$h_canon" = "$canon" ] && [ "$h_root" = "$root" ] && [ -n "$h_pid" ] && kill -0 "$h_pid" 2>/dev/null; then
            export CARGO_TARGET_DIR="$canon"
            echo "shared-target: on CARGO_TARGET_DIR=$canon (lock inherited from pid $h_pid, owner $root)" >&2
            return 0
        fi
    fi
    wait="${TILLANDSIAS_SHARED_TARGET_WAIT:-1800}"
    exec 9>>"$canon/.shared-target.lock"
    # ORPHAN-HELD LOCK. A flock lives as long as ANY process holds the fd, and
    # fd 9 is inherited by everything the builder spawns: a pty shell a gate
    # test leaves behind outlived the gate and held the lock for hours (profile
    # run 2, 1800 s REFUSED, recorded holder pid long dead). When the lock is
    # busy and the recorded holder is gone, only orphans hold it: retire that
    # inode (they keep the old one, harmlessly) and lock a fresh file.
    if ! flock -n 9; then
        local _hp
        _hp="$(sed -n 's/^pid \([0-9][0-9]*\) .*/\1/p' "$canon/.shared-target-holder" 2>/dev/null | head -n 1)"
        if [ -n "$_hp" ] && ! kill -0 "$_hp" 2>/dev/null; then
            echo "shared-target: lock holder pid $_hp is gone; the lock is held only by orphaned children; replacing the lock file" >&2
            exec 9>&-
            rm -f "$canon/.shared-target.lock"
            exec 9>>"$canon/.shared-target.lock"
        fi
    fi
    if ! flock -w "$wait" 9; then
        echo "shared-target: REFUSED, $canon is locked by another build for ${wait}s; last owner: $(cat "$owner" 2>/dev/null || echo unknown); lock holder: $(cat "$canon/.shared-target-holder" 2>/dev/null || echo unknown) (a long-lived shell that sourced shared_target_enter keeps the lock; see ps -p <pid>)" >&2
        return 1
    fi
    printf 'pid %s %s\n' "$$" "$(ps -o args= -p $$ 2>/dev/null | cut -c1-80)" > "$canon/.shared-target-holder" 2>/dev/null || true
    digest="$(shared_target_digest "$root")"
    prev="$(cat "$owner" 2>/dev/null || true)"
    if [ "$prev" != "$root $digest" ]; then
        # Not a ledger of intent: cargo trusts mtime alone, so make every
        # tracked file newer than whatever the previous owner built.
        git -C "$root" ls-files -z --full-name -- ":/" | (cd "$(git -C "$root" rev-parse --show-toplevel)" && xargs -0 touch -c 2>/dev/null) || true
        printf '%s %s\n' "$root" "$digest" > "$owner"
        echo "shared-target: owner changed (was: ${prev:-none}); tracked files of $root touched so cargo re-fingerprints from this checkout" >&2
    fi
    export CARGO_TARGET_DIR="$canon"
    export TILLANDSIAS_SHARED_TARGET_HELD="$canon|$root|$$"
    echo "shared-target: on CARGO_TARGET_DIR=$canon (locked, owner $root)" >&2
}
