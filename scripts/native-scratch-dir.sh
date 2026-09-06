#!/usr/bin/env bash
# ORDER 964-9yyp (slice B of 941-trcf). ONE probe for "is this worktree on a
# filesystem where scratch churn is unaffordable, and if so, where should the
# scratch live instead?"
#
# WHAT IT IS FOR, and the measurement that motivated it. On yolanda the Windows
# gate re-execs into the `tillandsias-build` WSL2 distro with the checkout at
# /mnt/c/..., i.e. 9p/drvfs. Measured 2026-09-02 in that distro, same binary,
# same ledger:
#
#   raw IO, cat every ledger file        9p  159ms   ext4    4ms   (~40x)
#   raw IO, find over plan/ (1406 files) 9p   94ms   ext4    4ms   (~23x)
#   tillandsias-plan check               9p  645ms   ext4  475ms   (1.4x)
#   archive-plan-packets.sh --check      9p 62331ms  ext4 5306ms   (11.7x)
#
# THE SPREAD IS THE WHOLE POINT AND IT IS WHY THIS IS A HELPER RATHER THAN A
# BLANKET STAGING PASS. A single fold of the ledger is CPU-bound in the YAML
# parse — 9p costs it 1.4x, and staging plan/ costs ~5.8s, so staging for the
# sake of one fold LOSES. The archiver check is a different animal: it copies
# plan/, rewrites the copy, copies it again and diffs the two trees, so it is
# metadata- and write-bound and 9p costs it 11.7x. Only callers with that shape
# should stage, which is why this file answers the question and does not act.
#
# NEVER STAGE ON A HOST THAT IS ALREADY FAST. On native Linux and macOS the
# fallback is the caller's existing path, unchanged, so a host that was correct
# before this order behaves identically after it — including keeping whatever
# cleanup discipline it already had.
#
# Usage:
#   . "$(dirname "${BASH_SOURCE[0]}")/native-scratch-dir.sh"
#   SCRATCH="$(native_scratch_dir <slug> <fallback-dir>)"
#
# `native_scratch_dir` always prints exactly one directory that exists and is
# writable, and returns 0. It prints the FALLBACK when the worktree is already
# fast, when no faster candidate can be found, or when the candidate cannot be
# created — a scratch dir the caller cannot write to would turn a slow check
# into a broken one, and slow is strictly better than broken.

# Filesystems whose metadata round trips cross a hypervisor or a network. The
# list is by NAME rather than by a latency probe on purpose: a probe would have
# to do IO to decide whether to avoid IO, and on the very host it is trying to
# help that measurement is the thing that is slow.
#
# `stat -f -c %T` names them; `df -T` is the fallback for a stat without -f
# (macOS's BSD stat, which is also a host we never stage on, so the fallback
# exists for tidiness rather than for a live path).
_NATIVE_SCRATCH_SLOW_FS="v9fs 9p fuseblk nfs nfs4 cifs smb2 smbfs virtiofs prl_fs vboxsf"

# The filesystem type of one directory, lowercased, or the empty string when it
# cannot be determined. An UNKNOWN type is never treated as slow: staging is an
# optimisation, and guessing wrong in that direction adds a copy for nothing.
# REFUSE TO BE EXECUTED (order 964-9yyp, second instance of esmeraldinha's
# lib-sigpipe-verdict.sh finding). This file is a LIBRARY: sourced it defines
# native_scratch_fstype / native_scratch_is_slow / native_scratch_dir; run
# directly it defines them into a shell that immediately exits, printing
# nothing and returning 0.
#
# THAT SILENCE COSTS A READER, measured on me 2026-09-06: verifying this
# packet's own closure I ran `bash scripts/native-scratch-dir.sh`, got no
# output, and read it against the closure's claim that the probe "always prints
# a directory that exists and is writable" — which looks exactly like a
# regression. It is the correct response to a wrong invocation. The tell was
# that the apparent defect was ABSOLUTE rather than partial, which is worth
# more as a heuristic than this guard is as a fix.
#
# The refusal is the half that matters here. esmeraldinha ALSO renamed theirs,
# because `check-sigpipe-verdict-measured.sh` could be wired as a guard by its
# prefix and pass by executing to zero bytes and exit 0. This file carries no
# such prefix and nothing would wire it as a check, so a rename would buy
# consistency and cost three call sites plus a memo digest — stated rather
# than silently skipped.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "refused:not-a-script:native-scratch-dir.sh is a library, not a command — source it and call native_scratch_dir <slug> <fallback>" >&2
    exit 2
fi


native_scratch_fstype() {
    local dir="$1" t=""
    t="$(stat -f -c %T "$dir" 2>/dev/null)" || t=""
    if [ -z "$t" ]; then
        t="$(df -T "$dir" 2>/dev/null | tail -1 | awk '{print $2}')" || t=""
    fi
    printf '%s\n' "$t" | tr '[:upper:]' '[:lower:]'
}

native_scratch_is_slow() {
    local t
    t="$(native_scratch_fstype "$1")"
    [ -n "$t" ] || return 1
    case " $_NATIVE_SCRATCH_SLOW_FS " in
        *" $t "*) return 0 ;;
    esac
    return 1
}

# Print a scratch directory for `slug`, on a fast filesystem when the worktree
# is on a slow one. `fallback` is what the caller used before this order and is
# printed unchanged whenever staging would not help or could not be arranged.
native_scratch_dir() {
    local slug="${1:?slug required}" fallback="${2:?fallback dir required}"
    # The question is about the WORKTREE, because that is where the caller's
    # scratch would otherwise land — not about $PWD, which a caller may have
    # changed.
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="$PWD"

    if ! native_scratch_is_slow "$root"; then
        printf '%s\n' "$fallback"
        return 0
    fi

    # Candidates in order. TMPDIR first because a caller that set it means it;
    # then the XDG cache, then /tmp. Each is accepted only if it is itself NOT
    # slow — on a host where the whole world is 9p there is nothing to win, and
    # a candidate inside the worktree would be the same filesystem wearing a
    # different path.
    local cand base
    for base in "${TMPDIR:-}" "${XDG_CACHE_HOME:-${HOME:-}/.cache}" /tmp; do
        [ -n "$base" ] || continue
        [ -d "$base" ] || continue
        native_scratch_is_slow "$base" && continue
        cand="$base/tillandsias-scratch/$slug"
        if mkdir -p "$cand" 2>/dev/null && [ -w "$cand" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done

    printf '%s\n' "$fallback"
    return 0
}
