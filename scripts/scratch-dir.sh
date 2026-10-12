#!/usr/bin/env bash
# @trace order:1637-cnxq
#
# scratch-dir.sh — print the ONE canonical scratch directory for
# development-runtime work, creating it. Everything disposable a script or a
# fixture makes on a developer host (temp trees, logs, private podman stores,
# any worktree) goes under it, nested by purpose:
#
#   scripts/scratch-dir.sh                -> <checkout>/scratch
#   scripts/scratch-dir.sh fixtures       -> <checkout>/scratch/fixtures
#   scripts/scratch-dir.sh worktrees      -> <checkout>/scratch/worktrees
#   scripts/scratch-dir.sh podman         -> <checkout>/scratch/podman
#   scripts/scratch-dir.sh logs           -> <checkout>/scratch/logs
#
# The idiom a new script uses (check-scratch-location-added.lua names it):
#
#   tmp="$(mktemp -d "$(scripts/scratch-dir.sh fixtures)/<name>.XXXXXX")"
#
# WHY INSIDE THE CHECKOUT (operator direction, 2026-10-12, order 1637-cnxq):
# an agent session's workspace is the checkout. A recursive rm OUTSIDE it goes
# to the operator for approval (consent:bash-policy:workspace-destroy,
# 1443-we89), and a session running in bypass mode that waits on that prompt
# halts the fleet. Scratch made inside the checkout is deleted without asking.
#
# WHY NOT target/: the build-cache sweep's `cargo clean`
# (scripts/check-build-cache-sweep.sh, due above 40 GiB or 14 days) removes
# target/ whole, and would take a sibling's worktree or podman store with it.
# WHY NOT work/: `git checkout work/<order>` is ambiguous the moment a path
# named work/<order> exists, and the work-ref namespace IS work/<order>.
#
# USER RUNTIME IS EXEMPT: inside a forge, /tmp and other absolute paths are
# fine, because the forge is destroyed on teardown. This helper is for the
# DEVELOPMENT runtime (a host's checkout), where nothing destroys scratch but
# the script that made it.
#
# TMPDIR: honoured only when it already lies inside the checkout, which is
# what build.sh's preflight door will set once its per-guard root moves under
# scratch/ (today the door roots at ${TMPDIR:-/tmp}/pf-guard.XXXXXX and sweeps
# that; a site made through this helper under the door is swept by the
# script's own trap instead). A TMPDIR elsewhere (darwin exports
# /var/folders/...) is ignored on purpose: it is the outside this helper exists
# to avoid. TILLANDSIAS_SCRATCH_ROOT (absolute) overrides the root explicitly.
#
# Verdicts (stderr; stdout is the path and nothing else):
#   refused:scratch-dir:no-root          exit 2  the checkout root could not be resolved
#   refused:scratch-dir:bad-subdir:<s>   exit 2  the subdir is absolute or climbs with ..
#   refused:scratch-dir:mkdir-failed:<p> exit 2  the directory could not be created
set -u

_afford() {  # <why> <remedy>
    echo "  why: $1" >&2
    echo "  remedy: $2" >&2
}

# Resolve the root BEFORE any cd (tool-resolution-after-cd, 2026-09): this
# file's own location, not the caller's cwd, names the checkout.
root="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd -P)" || root=""
if [ -z "$root" ]; then
    echo "refused:scratch-dir:no-root" >&2
    _afford "the directory above scripts/ could not be entered, so there is no checkout to put scratch in" \
        "run this helper from a checkout: scripts/scratch-dir.sh [<subdir>]"
    exit 2
fi

base="$root/scratch"
if [ -n "${TILLANDSIAS_SCRATCH_ROOT:-}" ]; then
    case "$TILLANDSIAS_SCRATCH_ROOT" in
        /*) base="$TILLANDSIAS_SCRATCH_ROOT" ;;
        *)
            echo "refused:scratch-dir:bad-root:$TILLANDSIAS_SCRATCH_ROOT" >&2
            _afford "TILLANDSIAS_SCRATCH_ROOT must be an absolute path; a relative one would move with the caller's cwd" \
                "export TILLANDSIAS_SCRATCH_ROOT=/absolute/path or unset it to use <checkout>/scratch"
            exit 2 ;;
    esac
elif [ -n "${TMPDIR:-}" ]; then                   # scratch-exception:preflight-door
    case "$TMPDIR" in                             # scratch-exception:preflight-door
        "$root"/*) base="$TMPDIR" ;;              # scratch-exception:preflight-door
    esac
fi

sub="${1:-}"
case "$sub" in
    "") ;;
    /*|..|../*|*/..|*/../*)
        echo "refused:scratch-dir:bad-subdir:$sub" >&2
        _afford "a subdir must stay under the scratch root: no leading /, no .. segment" \
            "name a plain subdir such as fixtures, worktrees, podman or logs"
        exit 2 ;;
esac

dir="$base${sub:+/$sub}"
if ! mkdir -p "$dir" 2>/dev/null; then
    echo "refused:scratch-dir:mkdir-failed:$dir" >&2
    _afford "the scratch directory could not be created (permissions, or a file in the way)" \
        "fix the path or set TILLANDSIAS_SCRATCH_ROOT to a writable absolute directory"
    exit 2
fi
printf '%s\n' "$dir"
