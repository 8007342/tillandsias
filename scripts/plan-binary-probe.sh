#!/usr/bin/env bash
# @trace spec:ci-release
#
# ONE probe for "which tillandsias-plan can this host actually run?", sourced by
# every script that needs the binary. Order 704-zcgi.
#
# WHY A SHARED COPY. Three scripts independently wrote the same wrong probe —
# `[ -x ./target/release/tillandsias-plan ]`, first match wins — and all three
# failed the same way on a shared Windows/WSL checkout, where a WSL build leaves
# a **Linux ELF** at exactly that path beside the usable `.exe`. Two of them
# (check-stranded-in-progress.sh, check-fragment-closure-evidence-added.sh) were
# fixed in place under 702-68zj; select-work-batch.sh then arrived from another
# host carrying a fresh copy of the same bug, which is the signal that fixing
# instances is not enough.
#
# THE RULE: an executable BIT is a claim; RUNNING the binary is evidence. The
# bit lies across the Windows/WSL boundary in both directions, and file
# extension alone cannot tell you which artifact a shared target/ dir last
# received. So probe by execution.
#
# Usage:
#   . "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
#   PLAN="$(resolve_plan_binary)" || { echo "refused:no-plan-binary:..."; exit 1; }
#   plan_binary_has closure-evidence-check || echo "skip:stale-plan-binary"
#
# `resolve_plan_binary` prints the path and exits 0, or prints nothing and
# returns 1. It never prints a verdict — the caller owns its own grammar.

# Print the first candidate that actually runs. `.exe` first: on the host where
# both exist, that is the runnable one.
resolve_plan_binary() {
    local candidate
    # An EXPLICIT override is the caller naming the binary, not a candidate to
    # be judged: honour it on existence alone. Running `capabilities` on it
    # would collapse a distinction the callers depend on — the litmus injects a
    # stub that fails the way a STALE binary fails, and a stale binary must
    # refuse as `stale-plan-binary`, never as `no-plan-binary`. Probing the
    # override turned the former into the latter and the corpus caught it
    # immediately (704-zcgi, first run).
    if [ -n "${TILLANDSIAS_PLAN_BIN:-}" ]; then
        [ -f "${TILLANDSIAS_PLAN_BIN}" ] || return 1
        printf '%s\n' "${TILLANDSIAS_PLAN_BIN}"
        return 0
    fi
    # CARGO_TARGET_DIR FIRST (order 783-jdeh). Every forge exports it
    # (images/default/lib-common.sh: CARGO_TARGET_DIR="$PROJECT_CACHE/cargo/target")
    # so that ./target/ does not exist in the mounted checkout at all. A probe
    # that looks only under ./target therefore cannot see the binary
    # cycle-preflight.sh JUST BUILT one line earlier, and reports
    # `blocked:preflight:plan:capabilities-refused` — blaming the instrument
    # for a path assumption and costing the forge its whole cycle. Measured on
    # yoga 2026-08-17: the forge lane died here with no ./target/ directory
    # while the build had succeeded.
    #
    # WINDOWS FOUND THE SAME DEFECT INDEPENDENTLY, same day, different cause —
    # recorded here because two unrelated causes converging on one line is the
    # argument for fixing it HERE rather than at either call site:
    # scripts/with-wsl2-builder.sh points CARGO_TARGET_DIR at a distro-native
    # path precisely so target/ never lands on 9p ("9p-backed target/ makes
    # cargo crawl"), so on that host too the just-built binary is not under
    # ./target and preflight refused a binary that ran fine and declared 35
    # capabilities. Their framing of the family is worth keeping: the four
    # earlier instances re-implemented the probe and looked in the right place
    # the wrong way; this one uses the shared probe correctly and the shared
    # probe looks in the wrong place.
    #
    # resolve_target_binary (order 770-ifeg), fifty lines below in THIS file,
    # already honours CARGO_TARGET_DIR. The newer generic probe learned the
    # lesson the older specific one still had — the fifth instance of the
    # path-assumption class 704-zcgi centralised this file to end.
    local ctd="${CARGO_TARGET_DIR:-}"
    if [ -n "$ctd" ] && [ "${ctd#/}" = "$ctd" ]; then
        ctd="./$ctd"
    fi
    for candidate in \
        ${ctd:+"$ctd/release/tillandsias-plan.exe"} \
        ${ctd:+"$ctd/debug/tillandsias-plan.exe"} \
        ${ctd:+"$ctd/release/tillandsias-plan"} \
        ${ctd:+"$ctd/debug/tillandsias-plan"} \
        ./target/release/tillandsias-plan.exe \
        ./target/debug/tillandsias-plan.exe \
        ./target/release/tillandsias-plan \
        ./target/debug/tillandsias-plan \
        "$(command -v tillandsias-plan 2>/dev/null)"; do
        [ -n "$candidate" ] || continue
        [ -f "$candidate" ] || continue
        # `capabilities` is the right probe rather than `--help`: it exits 0
        # only on a binary built from sources carrying order 569, and its
        # output is the capability set the caller may want next.
        if "$candidate" capabilities >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# True when the resolved binary carries a named subcommand. Lets a caller
# distinguish "this binary predates the rule I enforce" (host state — skip and
# say so) from "the thing I check is wrong" (a real finding). Conflating those
# is how a stale binary produced a red gate naming three violations that did
# not exist (702-68zj).
plan_binary_has() {
    local bin="$1" subcommand="$2"
    "$bin" capabilities 2>/dev/null | grep -qx "$subcommand"
}

# ── Generic run-don't-stat probe for ANY target/ binary (order 770-ifeg) ─────
#
# The same rule generalized beyond tillandsias-plan. Every script that execs a
# target/(debug|release)/<name> artifact after an existence or `-x` check has
# the identical bug on a shared Windows/WSL checkout: a WSL build leaves a
# Linux ELF at exactly that extensionless path beside the runnable `.exe`, the
# exact-name match wins over the shell's `.exe` fallback, and the script dies
# with "Exec format error" (~30s lost per run of regenerate-cheatsheet-index.sh
# on the windows host — see
# plan/issues/windows-host-tooling-hits-linux-elves-in-target-2026-08-16.md).
#
# target_binary_runs <path>: true when the OS loader actually executes the
# file. Exit 126 (found but cannot execute — wrong format, no permission) and
# 127 (not runnable) are the loader saying no; ANY other exit code means the
# artifact ran, which is the evidence an executable bit only claims. `--help`
# is the probe argument because every workspace binary answers it without side
# effects; callers that must also gate on binary VERSION keep using
# resolve_plan_binary's `capabilities` probe, which is a stricter contract.
target_binary_runs() {
    [ -f "$1" ] || return 1
    "$1" --help >/dev/null 2>&1
    local rc=$?
    [ "$rc" -ne 126 ] && [ "$rc" -ne 127 ]
}

# resolve_target_binary <name> [profile] [root]
#   Print the first runnable candidate for a cargo-built binary and exit 0, or
#   print nothing and return 1. `.exe` first: on the host where both artifacts
#   exist, that is the runnable one. Honours CARGO_TARGET_DIR (absolute or
#   root-relative) ahead of <root>/target, matching cargo's own resolution.
#   profile defaults to debug — the profile `cargo build` produces.
resolve_target_binary() {
    local name="$1" profile="${2:-debug}" root="${3:-.}"
    local ctd="${CARGO_TARGET_DIR:-}" dir candidate
    if [ -n "$ctd" ] && [ "${ctd#/}" = "$ctd" ]; then
        ctd="$root/$ctd"
    fi
    for dir in ${ctd:+"$ctd/$profile"} "$root/target/$profile"; do
        for candidate in "$dir/$name.exe" "$dir/$name"; do
            if target_binary_runs "$candidate"; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
    done
    return 1
}
