#!/usr/bin/env bash
# @trace order:891-5shq
#
# lib-env-forward.sh — the ONE implementation of "carry the TILLANDSIAS_*
# namespace across a dispatch boundary".
#
# WHY THIS FILE EXISTS. Neither `toolbox run` nor `wsl.exe` forwards the
# caller's environment, so every TILLANDSIAS_* control flag died silently at
# each boundary. It was found, diagnosed, fixed and WRITTEN DOWN on the toolbox
# boundary (order 889-8tcb, and the comment there names the cost: on Silverblue
# TILLANDSIAS_FORCE_CHECK=1 could not bypass the gate memo and
# TILLANDSIAS_SKIP_VERSION_BUMP=1 could not stop the version bump). The WSL
# boundary in the same repo then received its own separate copy of the same
# four lines.
#
# TWO COPIES OF A FIX IS THE DEFECT 891-5shq NAMES, not a tidy-up: its fourth
# exit criterion is that "the two dispatches share the forwarding logic, or a
# check proves they agree — a third boundary must not be able to diverge
# silently the way this one did". Sharing is the stronger of the two options
# offered, because it makes divergence impossible rather than merely
# detectable, and a third dispatch now has something to call instead of a
# fourth thing to reimplement.
#
# WHAT AN ESCAPE HATCH THAT DOES NOT CROSS ACTUALLY COSTS. `./build.sh --check`
# prints "TILLANDSIAS_FORCE_CHECK=1 to re-run" on every ok:gate-fresh line, and
# the meta-orchestration skill documents that flag as THE way to make a green
# mean something. Where it does not cross, that instruction is silently false
# and the reader believes a re-run happened. That is worse than having no
# escape hatch, because no-hatch is at least honest.

# tillandsias_env_forward_prefix [namespace_prefix]
#
# Print a shell fragment of `export NAME=VALUE; ` assignments, one per exported
# or set variable whose name begins with `namespace_prefix` (default
# `TILLANDSIAS_`). The caller prepends the result to the command string it
# hands across the boundary.
#
# VALUES ARE %q-QUOTED, both name and value. The fragment is evaluated by a
# remote `bash -c`, so an unquoted value containing a space, a quote or a `;`
# would be a command-injection seam rather than a forwarded flag.
#
# IT MUST NEVER MANUFACTURE A VALUE. 891-5shq's third exit criterion is a
# NEGATIVE CONTROL: a flag that is not set on the host must not appear set on
# the far side. `compgen -v` lists only variables that actually exist, so an
# unset name yields no assignment at all — and that property is pinned by the
# fixture rather than left to inspection, because "forwards correctly" and
# "exports everything it can think of" look identical from the near side.
tillandsias_env_forward_prefix() {
    local ns="${1:-TILLANDSIAS_}"
    local out="" v
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        out="${out}export $(printf '%q' "$v")=$(printf '%q' "${!v}"); "
    done < <(compgen -v | grep "^${ns}" || true)
    printf '%s' "$out"
}
