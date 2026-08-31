#!/usr/bin/env bash
# @trace spec:enclave-network
# @trace order:245
#
# ORDER 245 §5 P8. Keep openspec/specs/enclave-network/spec.md's membership list
# in agreement with the code that actually attaches containers to the enclave.
#
# THE DEFECT THIS EXISTS FOR, measured 2026-08-30. The spec enumerated the
# members in PROSE — "forge, git, inference, and proxy" — in two places. By the
# time it was checked, FIVE more services had joined and none had been added:
# vault (`launch_vault_container`), the router, the nix cache (order 801-vm4p),
# the catalog service, and the observatorium web. A reader asking "what is on
# the enclave?" got a four-item answer to an eleven-site question, and vault —
# central to the spec's own dependency story — was one of the missing ones.
#
# Order 801-vm4p's nix cache had by then gone unrecorded in TWO documents: the
# network architecture audit's §3 dependency graph and this spec. One landed
# service, two stale prose lists, is what makes prose the wrong container for
# this fact.
#
# WHAT THIS CHECKS. Every attach site's ENCLOSING FUNCTION must be named in the
# spec, and every function the spec names must still be an attach site. Symbols,
# not line numbers, for the reason order 881-29me requires of audit citations: a
# symbol survives every edit that does not rename it, and a rename is a real
# event worth noticing.
#
# WHAT IT DELIBERATELY DOES NOT CHECK: whether a service SHOULD be on the
# enclave. That is a design question. This only refuses the silent divergence
# between what attaches and what is written down.
#
# Verdict grammar, one line on stdout:
#   ok:enclave-membership:<n> attach site(s) documented   exit 0
#   violation:enclave-membership:undocumented=<n>:stale=<n>  exit 1
#   blocked:<reason>                                      exit 2
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

SPEC="${TILLANDSIAS_ENCLAVE_SPEC:-openspec/specs/enclave-network/spec.md}"
SRC_ROOT="${TILLANDSIAS_ENCLAVE_SRC_ROOT:-crates}"

[ -r "$SPEC" ] || { echo "blocked:spec-unreadable:$SPEC"; exit 2; }
[ -d "$SRC_ROOT" ] || { echo "blocked:src-root-missing:$SRC_ROOT"; exit 2; }

# Attach sites: Rust that puts a container on the enclave. THREE constants name
# it and all three must be matched — missing one is how the first draft of this
# guard reported `build_git_run_args` as no longer attaching when it does:
#   ENCLAVE_NET          the enclave alone
#   ENCLAVE_ONLY_NET     the git mirror's enclave-only form (order 606-9wqd)
#   ENCLAVE_EGRESS_NETS  the dual-homed pair (proxy, and the login helper)
#
# Only TOP-LEVEL functions are tracked (`fn` at column 0). A nested helper —
# `fn chown_tree` inside `build_inference_run_args` — otherwise steals the
# attribution and the enclosing builder reads as absent. That was the second
# bug in this guard's first draft, and it failed in the SAFE direction only by
# luck.
#
# The #[cfg(test)] region is cut before scanning: a test named
# `build_web_service_run_args_bind_mounts_worktree_read_only` matched the
# `build_*` filter and was reported as an undocumented enclave member.
attach_functions() {
    local f
    while IFS= read -r f; do
        awk '
            /^(pub |pub\(crate\) |async |pub async )?fn [a-z_]+/ {
                if (match($0, /fn [a-z_]+/)) { fname = substr($0, RSTART+3, RLENGTH-3) }
                next
            }
            /ENCLAVE_NET|ENCLAVE_ONLY_NET|ENCLAVE_EGRESS_NETS/ {
                if (fname ~ /^(build|launch)_/) { print fname }
            }
        ' "$f"
    done < <(grep -rl 'ENCLAVE_NET\|ENCLAVE_ONLY_NET\|ENCLAVE_EGRESS_NETS' --include='*.rs' "$SRC_ROOT" 2>/dev/null) | sort -u
}

# Functions the spec names, read from the bullet list's `fn <name>` spans.
spec_functions() {
    grep -oE '`fn [a-z_]+`' "$SPEC" 2>/dev/null | sed 's/`fn //; s/`//' | sort -u
}

actual="$(attach_functions)"
listed="$(spec_functions)"

if [ -z "$actual" ]; then
    echo "blocked:no-attach-sites-parsed"
    exit 2
fi
if [ -z "$listed" ]; then
    echo "blocked:spec-names-no-attach-functions"
    exit 2
fi

undocumented="$(comm -23 <(printf '%s\n' "$actual") <(printf '%s\n' "$listed"))"
stale="$(comm -13 <(printf '%s\n' "$actual") <(printf '%s\n' "$listed"))"

n_undoc=$(printf '%s' "$undocumented" | grep -c . || true)
n_stale=$(printf '%s' "$stale" | grep -c . || true)
n_actual=$(printf '%s\n' "$actual" | grep -c . || true)

if [ "$n_undoc" -ne 0 ] || [ "$n_stale" -ne 0 ]; then
    [ "$n_undoc" -ne 0 ] && {
        echo "  Functions that attach to the enclave and are NOT named in $SPEC:" >&2
        printf '%s\n' "$undocumented" | sed 's/^/    undocumented: /' >&2
    }
    [ "$n_stale" -ne 0 ] && {
        echo "  Functions $SPEC names that no longer attach to the enclave:" >&2
        printf '%s\n' "$stale" | sed 's/^/    stale:        /' >&2
    }
    echo "  The membership list is symbol-anchored precisely so this cannot drift" >&2
    echo "  in silence: a prose list went stale by five members before this guard" >&2
    echo "  existed (order 245 P8). Add or remove the bullet in the SAME commit as" >&2
    echo "  the attach change." >&2
    echo "violation:enclave-membership:undocumented=${n_undoc}:stale=${n_stale}"
    exit 1
fi

echo "ok:enclave-membership:${n_actual} attach site(s) documented"
exit 0
