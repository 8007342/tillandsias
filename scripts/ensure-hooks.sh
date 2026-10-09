#!/usr/bin/env bash
# @trace order:1255-s4im
#
# ensure-hooks.sh — make sure THIS checkout's push guards are armed, with
# nothing but bash and git.
#
# THE DEFECT THIS CLOSES (1255-s4im). Every push guard — the release freeze,
# the local gate, the VERSION guard, the linux-next merge gate — lives in the
# pre-push hook, and the only caller of scripts/install-hooks.sh was build.sh.
# A host with no Rust toolchain cannot run build.sh, so the FLOOR-TIER hosts
# never got hooks. Reproduced 2026-10-09 on darwin with scratch remotes: a
# fresh clone had 0 non-sample hooks, `release-freeze.sh set linux-next`
# froze the remote, and a code push to linux-next was ACCEPTED (rc 0). The
# same push from a clone that had run install-hooks.sh with no cargo on PATH
# was refused. install-hooks.sh never needed a toolchain; nothing called it.
#
# WHAT IT DOES. Reads the pre-push hook git will RUN (`--git-path hooks`,
# which honours core.hooksPath exactly as install-hooks.sh does) and:
#   * ours and current           -> nothing to do
#   * absent                     -> runs install-hooks.sh
#   * ours but an older marker   -> runs install-hooks.sh, which upgrades it
#   * NOT ours (no tillandsias-pre-push marker) -> REFUSES. It never overwrites
#     a hook it did not write; the operator decides what happens to it.
#   * core.hooksPath from global/system config -> REFUSES, as install-hooks.sh
#     does (1442-wyf9): arming these guards in every repo on the box is wrong.
# After an install it re-reads the hook, so "installed" means the current
# marker is on disk, not that the installer exited 0.
#
# --prelude: the mode the plan-lane scripts call (push-plan-fragments-to-
# trunk.sh, claim-ledger-node.sh, salvage-dirty-worktree.sh, drain-queue.sh),
# so a floor host's FIRST plan-lane action arms the guards before its own push.
#   * SILENT on ok — existing hosts see no change in those scripts' output;
#   * acts only when `origin` is the GitHub repository (or
#     TILLANDSIAS_ENSURE_HOOKS=1): fixtures run these scripts in scratch repos
#     with local remotes, and arming hooks there would change what they test;
#   * TILLANDSIAS_ENSURE_HOOKS=0 turns it off;
#   * ALWAYS exits 0 — a refusal is printed (stderr) but never fails the
#     caller, because a new hard failure in a lane every host uses is exactly
#     what the operator ruled out for this migration (1315-4a7j).
#
# VERDICTS (stdout, one line; why/remedy on stderr for refusals):
#   ok:hooks:<marker>
#   installed:hooks:<marker>
#   upgraded:hooks:<old>-><new>
#   refused:hooks:foreign-pre-push:<path>          exit 3
#   refused:hooks:<scope>-hooks-path:<dir>         exit 3
#   refused:hooks:install-failed:<detail>          exit 3
#   refused:hooks:not-a-checkout                   exit 2
# In --prelude mode every verdict goes to stderr and the exit is always 0.
set -uo pipefail

PRELUDE=0
[ "${1:-}" = "--prelude" ] && PRELUDE=1

ROOT="${TILLANDSIAS_ENSURE_HOOKS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALLER="$ROOT/scripts/install-hooks.sh"

_afford() { echo "  why: $1" >&2; echo "  remedy: $2" >&2; }
# A verdict goes to stdout, except in prelude mode: the calling script's stdout
# is its own contract (claim verdicts are parsed), so the prelude writes stderr.
_say() { if [ "$PRELUDE" -eq 1 ]; then echo "$1" >&2; else echo "$1"; fi; }
# In prelude mode nothing here may fail the caller.
_exit() { if [ "$PRELUDE" -eq 1 ]; then exit 0; else exit "$1"; fi; }

if [ "$PRELUDE" -eq 1 ]; then
    case "${TILLANDSIAS_ENSURE_HOOKS:-}" in
        0) exit 0 ;;
        1) ;;
        *)
            url="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" || exit 0
            case "$url" in
                *github.com[:/]8007342/tillandsias|*github.com[:/]8007342/tillandsias.git) ;;
                *) exit 0 ;;
            esac
            ;;
    esac
fi

hooks_dir="$(git -C "$ROOT" rev-parse --path-format=absolute --git-path hooks 2>/dev/null)" || {
    _say "refused:hooks:not-a-checkout"
    _afford "$ROOT is not a git checkout, so there is no hook for git to run" \
        "run this from the project checkout"
    _exit 2
}

# The current marker is the installer's, read from it so the two cannot drift.
want="$(sed -n 's/^PREPUSH_MARKER="# \(tillandsias-pre-push-v[0-9][0-9]*\)"$/\1/p' "$INSTALLER" 2>/dev/null)"
if [ -z "$want" ]; then
    _say "refused:hooks:install-failed:no-marker-in-installer"
    _afford "scripts/install-hooks.sh names no PREPUSH_MARKER, so the current hook version is unknowable" \
        "restore scripts/install-hooks.sh from the trunk"
    _exit 3
fi

scope="$(git -C "$ROOT" config --show-scope --get core.hooksPath 2>/dev/null | cut -f1)" || scope=""
case "$scope" in
    ''|local|worktree) ;;
    *)
        _say "refused:hooks:${scope}-hooks-path:$hooks_dir"
        _afford "core.hooksPath comes from $scope config, so installing would arm these guards in every repository on this machine (1442-wyf9)" \
            "give this clone its own hooks dir: git -C \"$ROOT\" config core.hooksPath \"\$(git -C \"$ROOT\" rev-parse --path-format=absolute --git-common-dir)/hooks\", then re-run scripts/ensure-hooks.sh"
        _exit 3
        ;;
esac

hook="$hooks_dir/pre-push"
# Any pre-push this project ever generated: the versioned markers, and the
# pre-v2 version guard. Everything else is someone else's hook.
have=""
if [ -f "$hook" ]; then
    have="$(grep -oE 'tillandsias-pre-push-v[0-9]+' "$hook" 2>/dev/null | head -n 1)"
    if [ -z "$have" ] && grep -qF '# version-guard-hook' "$hook" 2>/dev/null; then
        have="version-guard-hook"
    fi
    if [ -z "$have" ]; then
        _say "refused:hooks:foreign-pre-push:$hook"
        _afford "a pre-push hook that this project did not write is installed, and overwriting it would silently discard whatever it enforces" \
            "inspect $hook; if it is not needed, move it aside (mv \"$hook\" \"$hook.local\") and re-run scripts/ensure-hooks.sh — or fold its checks into scripts/hooks/"
        _exit 3
    fi
    if [ "$have" = "$want" ]; then
        [ "$PRELUDE" -eq 1 ] || echo "ok:hooks:$want"
        exit 0
    fi
fi

# Absent, or ours and older. The installer is bash-only (no toolchain).
if ! out="$(bash "$INSTALLER" 2>&1)"; then
    _say "refused:hooks:install-failed:installer-exit"
    printf '%s\n' "$out" | sed 's/^/  | /' >&2
    _afford "scripts/install-hooks.sh failed, so this checkout's pushes are still unguarded" \
        "read the installer output above and re-run scripts/ensure-hooks.sh"
    _exit 3
fi
now="$(grep -oE 'tillandsias-pre-push-v[0-9]+' "$hook" 2>/dev/null | head -n 1)"
if [ "$now" != "$want" ]; then
    _say "refused:hooks:install-failed:marker=${now:-none}:want=$want"
    printf '%s\n' "$out" | sed 's/^/  | /' >&2
    _afford "the installer ran but $hook does not carry $want, so the guards are not armed" \
        "read the installer output above; an older marker it does not recognise needs moving aside by hand"
    _exit 3
fi
if [ -n "$have" ]; then
    _say "upgraded:hooks:$have->$want"
else
    _say "installed:hooks:$want"
    echo "  this checkout's pushes were unguarded until now (1255-s4im)" >&2
fi
exit 0
