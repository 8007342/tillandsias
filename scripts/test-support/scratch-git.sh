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

_scratch_git_real="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" rev-parse --absolute-git-dir 2>/dev/null)"

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
    case "$sub" in init|clone) git -C "$d" "$@"; return ;; esac
    if [ -n "$_scratch_git_real" ] && [ "$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null)" = "$_scratch_git_real" ]; then
        echo "FAIL: scratch_git: [$d] resolves to the REAL checkout's git dir; a fixture writes only scratch repos (2245-scgt)" >&2
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
