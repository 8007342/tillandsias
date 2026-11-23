# shellcheck shell=bash
# @trace order:2245-scgt, order:2244-crgd, order:2224-gdir
#
# scripts/test-support/scratch-git.sh — sourced by fixtures that drive git in
# SCRATCH repos. Two helpers, so no arm can reach the real checkout:
#
#   scratch_git <dir> <git args...>
#       `git -C <dir> ...`, refused (exit 2, named) when <dir> is EMPTY (an
#       empty -C is the cwd) or resolves to THIS checkout's git dir (a scratch
#       whose .git is gone resolves upward). Reads of the real repo use plain
#       `git -C "$ROOT"`; this helper is for scratch repos only.
#
#   scratch_trap '<cleanup>'
#       EXIT runs <cleanup>; INT and TERM run it and EXIT (130/143). A trap
#       that only cleans up lets bash RESUME after a kill, with the scratch gone
#       and a `D="$(...)"` left empty (2244-crgd: calmecacpilli's origin was
#       rewritten that way after the preflight door deadline-killed a fixture).
#
# The real git dir is the checkout this helper sits in, found from its own path.

# _sg_dir <dir> <rev-parse flag>: that answer as a physical path, or nothing.
# (`cd ""` succeeds in place, so an empty answer is dropped, never cd'd into.)
_sg_dir() {
    local o
    o="$(git -C "$1" rev-parse "$2" 2>/dev/null)" && [ -n "$o" ] || return 1
    (cd "$1" && cd "$o" && pwd -P) 2>/dev/null
}
_scratch_git_top="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# The COMMON dir, not the per-worktree git dir: it holds the config that
# `remote set-url` writes and that every worktree of the checkout shares.
_scratch_git_common="$(_sg_dir "$_scratch_git_top" --git-common-dir)"

scratch_git() {
    local d="${1:-}"
    shift || true
    if [ -z "$d" ]; then
        echo "FAIL: scratch_git: empty repo path — an empty -C is the cwd, which may be the real checkout (2245-scgt)" >&2
        exit 2
    fi
    # `init` and `clone` CREATE the scratch repo: before they run, a dir under
    # the checkout (target/plan-scratch/...) still resolves upward to it.
    # The subcommand is the first argument that is not an option (`-c k=v`
    # takes its value with it).
    local a sub="" skip=0
    for a in "$@"; do
        if [ "$skip" = 1 ]; then skip=0; continue; fi
        case "$a" in -c|-C) skip=1 ;; -*) ;; *) sub="$a"; break ;; esac
    done
    if [ -n "${GIT_DIR:-}${GIT_WORK_TREE:-}${GIT_COMMON_DIR:-}" ]; then
        echo "FAIL: scratch_git: GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR is set and overrides -C [$d]; unset it first (2224-gdir)" >&2
        exit 2
    fi
    case "$sub" in init|clone) git -C "$d" "$@"; return ;; esac
    # A scratch repo is ROOTED at <dir>: its top level (or, bare, its git dir) is
    # <dir> itself. Anything else resolved UPWARD into an enclosing repo.
    local pd top common
    pd="$(cd "$d" 2>/dev/null && pwd -P)" || {
        echo "FAIL: scratch_git: [$d] does not exist; init or clone it first (2245-scgt)" >&2
        exit 2
    }
    if [ "$(git -C "$pd" rev-parse --is-bare-repository 2>/dev/null)" = true ]; then
        top="$(_sg_dir "$pd" --absolute-git-dir)"
    else
        top="$(_sg_dir "$pd" --show-toplevel)"
    fi
    common="$(_sg_dir "$pd" --git-common-dir)"
    if [ "$top" != "$pd" ] || [ -z "$common" ] || [ "$common" = "$_scratch_git_common" ]; then
        echo "FAIL: scratch_git: [$d] is not a scratch repo rooted there (top [${top:-none}], common dir [${common:-none}]); it may be the REAL checkout (2245-scgt)" >&2
        exit 2
    fi
    git -C "$d" "$@"
}

scratch_trap() {
    # shellcheck disable=SC2064  # expand the cleanup now, as the caller wrote it
    trap "$1" EXIT
    # shellcheck disable=SC2064
    trap "$1; exit 143" TERM
    # shellcheck disable=SC2064
    trap "$1; exit 130" INT
}
