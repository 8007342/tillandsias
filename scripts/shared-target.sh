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

# ORDER 2146-4svj. shared_target_forget_build_scripts CANON ROOT
#
# Touching this checkout's files is NOT enough for a build script that emits
# cargo:rerun-if-changed: cargo then reruns it only when THOSE paths change,
# and they are ABSOLUTE paths into whichever checkout last ran it. Cargo keeps
# one build-script unit per feature set and profile, and the unit's identity
# does not include the checkout path, so each unit is owned by whichever
# worktree built it last — not necessarily the previous owner. Measured
# 2026-11-20 on lenovinha: a gate in wt-2118-tnut linked tillandsias-embed's
# test unit built a day earlier from wt-gate-2112 (651 assets against this
# tree's 653), and a first fix that forgot only the PREVIOUS owner's outputs
# left it red. A green gate could equally have vouched for another worktree's
# assets.
#
# So every build script whose recorded rerun-if-changed paths belong to a
# checkout OTHER than ROOT is forgotten (its run fingerprint and its output),
# and cargo reruns it here. A path belongs to the LONGEST checkout root that
# contains it (git worktree list; the main checkout contains target/work/*
# worktrees), so a path under a deleted worktree belongs to the main
# checkout and is forgotten too. Paths outside every checkout (the cargo
# registry, /usr) and a build script's own OUT_DIR (<target>/.../build/<unit>/out)
# never cause a forget. Not "anything under the target dir": this clone's
# worktrees live in target/work/, inside it, and a first draft that excluded
# the whole target dir kept a wt-gate-2112 unit it should have forgotten. Over-forgetting costs a rerun, never a
# wrong verdict. Prints how many it forgot.
shared_target_forget_build_scripts() {
    local canon="$1" root="$2" roots out dir name n=0
    [ -n "$canon" ] && [ -d "$canon" ] && [ -n "$root" ] || { echo 0; return 0; }
    roots="$(git -C "$root" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')"
    roots="$(printf '%s\n%s\n' "$roots" "$root" | sed '/^$/d' | LC_ALL=C sort -u)"
    while IFS= read -r out; do
        [ -n "$out" ] || continue
        dir="${out%/output}"            # <profile>/build/<pkg>-<hash>
        name="${dir##*/}"
        rm -rf -- "${dir%/build/*}/.fingerprint/$name" "$dir"
        n=$((n + 1))
    done < <(
        # shellcheck disable=SC2016 — awk program, not shell
        awk -v cur="$root" -v roots="$roots" -v canon="$canon" '
            BEGIN { nr = split(roots, R, "\n") }
            FNR == 1 { flagged = 0 }
            flagged { next }
            /^cargo::?rerun-if-changed=\// {
                p = $0; sub(/^cargo::?rerun-if-changed=/, "", p)
                # the OUT_DIR of a build script. NOT every path under the target
                # dir: the worktrees of this clone live in target/work/, inside it.
                if (index(p, canon "/") == 1 && p ~ /\/build\/[^\/]+\/out(\/|$)/) next
                best = ""
                for (i = 1; i <= nr; i++) {
                    r = R[i]
                    if (r != "" && (p == r || index(p, r "/") == 1) && length(r) > length(best)) best = r
                }
                if (best != "" && best != cur) { print FILENAME; flagged = 1 }
            }
        ' "$canon"/*/build/*/output "$canon"/*/*/build/*/output 2>/dev/null
    )
    echo "$n"
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
    # @trace order:1840-2p9v — NO FLOCK IS "OFF", NOT A REFUSAL. Stock macOS
    # ships no flock(1), and refusing here redded every Mac preflight
    # (macbookair 2026-10-23: test-gate-step-host-state-retry 0/4,
    # test-script-run-verb ARM 5). The shared dir is a cache; without a lock
    # it cannot be shared safely, so the checkout keeps its own target/ —
    # exactly the other off paths above.
    if ! command -v flock >/dev/null 2>&1; then
        echo "shared-target: off (no flock on PATH to serialize the shared dir; this checkout keeps its own target/)" >&2; return 0
    fi
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
        _st_forgot="$(shared_target_forget_build_scripts "$canon" "$root")"
        printf '%s %s\n' "$root" "$digest" > "$owner"
        echo "shared-target: owner changed (was: ${prev:-none}); tracked files of $root touched so cargo re-fingerprints from this checkout; ${_st_forgot} build script(s) that read another checkout will rerun (2146-4svj)" >&2
    fi
    export CARGO_TARGET_DIR="$canon"
    export TILLANDSIAS_SHARED_TARGET_HELD="$canon|$root|$$"
    echo "shared-target: on CARGO_TARGET_DIR=$canon (locked, owner $root)" >&2
}

# Executed rather than sourced (the fixture's entry point,
# scripts/lua/test-shared-target-forgets-build-scripts.lua).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        forget-build-scripts) shift; shared_target_forget_build_scripts "$@"; exit $? ;;
        *) echo "usage: scripts/shared-target.sh forget-build-scripts <canon> <root>  (or source it)" >&2; exit 2 ;;
    esac
fi
