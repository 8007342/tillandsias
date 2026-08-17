#!/usr/bin/env bash
# @trace spec:forge-environment-discoverability
#
# dev-host-experts.sh — declare a host a DEVELOPMENT ENVIRONMENT so the expert
# lifecycle (spec-index build, post-commit refresh) runs on it.
#
# SOURCE this for the effect; EXECUTE it to manage the declaration:
#
#     . "$(dirname "${BASH_SOURCE[0]}")/dev-host-experts.sh"   # exports the var
#     scripts/dev-host-experts.sh --enable | --disable | --status
#
# WHY THIS EXISTS. Order 685-yidq gates the post-commit expert refresh behind
# TILLANDSIAS_HOST_EXPERTS so CI and plain checkouts never rebuild an index.
# The gate is right; nothing ever SET the variable. Measured 2026-08-17 on two
# hosts independently (macuahuitl and yoga): the refresh has never run on
# either, so the spec index goes stale silently and `spec_answer` answers from
# whatever was last built by hand. yoga found it by checking execution rather
# than wiring, one cycle after deleting a guard partly for being ineffective.
#
# DEVELOPMENT ENVIRONMENT ONLY. The END USER RUNTIME lives inside the enclave,
# where the forge launch path owns the expert lifecycle (ensure_forge_experts)
# and must not be second-guessed by a host-side declaration. So this refuses
# inside a forge, unconditionally, even if the marker is somehow visible there.
#
# IDEMPOTENT BY CONSTRUCTION, three ways, because "idempotent for every
# environment that uses it" is the operator's stated requirement:
#   1. An ALREADY-SET value is never overwritten — including an empty one, so
#      `TILLANDSIAS_HOST_EXPERTS= <cmd>` is a working per-invocation opt-out.
#   2. Sourcing twice does exactly what sourcing once did.
#   3. --enable on an enabled host, and --disable on a disabled one, are no-ops
#      that still report the resulting state.
#
# DELIBERATELY A DECLARATION, NOT AN INFERENCE. "Am I a development host" is a
# per-machine fact that cannot be derived: a cargo toolchain and a checkout are
# equally present on CI and on any clone, which is precisely what 685-yidq's
# gate exists to keep out. So it reads a host-local marker a human (or this
# script) created on purpose. The marker is UNTRACKED and host-local for the
# reason 789-nc2s recorded the hard way: a tracked config carrying a
# machine-specific value reached every host in the fleet and broke the ones it
# did not describe.
#
# This file sets NO shell options and installs NO traps. It is sourced by
# hooks and preflights that own their own error handling, and a sourced file
# that turns on `set -euo pipefail` silently rewrites its sourcer's semantics
# (orders 731-pc5r and 764-sunk are two instances of exactly that).

_tdhe_marker_path() {
    printf '%s/tillandsias/dev-host-experts\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# Resolve the declaration WITHOUT mutating anything. Prints one of:
#   forge | preset | declared | absent
_tdhe_state() {
    if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
        printf 'forge\n'
        return 0
    fi
    # `+x` distinguishes "set to empty" from "unset". An explicit empty value
    # is an opt-out and must survive, so test for SET-ness, not truthiness.
    if [ -n "${TILLANDSIAS_HOST_EXPERTS+x}" ]; then
        printf 'preset\n'
        return 0
    fi
    if [ -f "$(_tdhe_marker_path)" ]; then
        printf 'declared\n'
        return 0
    fi
    printf 'absent\n'
}

# The sourced effect: export only when this host has declared itself.
_tdhe_apply() {
    case "$(_tdhe_state)" in
        declared)
            TILLANDSIAS_HOST_EXPERTS=1
            export TILLANDSIAS_HOST_EXPERTS
            ;;
        forge | preset | absent)
            : # no-op, by contract
            ;;
    esac
}

# Executed rather than sourced? ${BASH_SOURCE[0]} equals $0 only when run.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    _tdhe_main() {
        _tdhe_m="$(_tdhe_marker_path)"
        case "${1:---status}" in
            --enable)
                mkdir -p "$(dirname "$_tdhe_m")" || {
                    printf 'blocked:dev-host-experts:cannot-create-config-dir\n' >&2
                    return 1
                }
                if [ ! -f "$_tdhe_m" ]; then
                    {
                        printf '# Declares this host a Tillandsias DEVELOPMENT ENVIRONMENT.\n'
                        printf '# Created by scripts/dev-host-experts.sh --enable.\n'
                        printf '# Untracked and host-local ON PURPOSE (789-nc2s): a tracked\n'
                        printf '# machine-specific value reaches every host in the fleet.\n'
                        printf '# Remove it, or run --disable, to opt out.\n'
                    } >"$_tdhe_m" || {
                        printf 'blocked:dev-host-experts:cannot-write-marker\n' >&2
                        return 1
                    }
                fi
                printf 'ok:dev-host-experts:enabled:%s\n' "$_tdhe_m"
                ;;
            --disable)
                rm -f "$_tdhe_m" || {
                    printf 'blocked:dev-host-experts:cannot-remove-marker\n' >&2
                    return 1
                }
                printf 'ok:dev-host-experts:disabled\n'
                ;;
            --status)
                printf 'ok:dev-host-experts:%s\n' "$(_tdhe_state)"
                ;;
            *)
                printf 'refused:dev-host-experts:unknown-argument:%s\n' "${1}" >&2
                return 2
                ;;
        esac
    }
    _tdhe_main "$@"
    exit $?
fi

_tdhe_apply
