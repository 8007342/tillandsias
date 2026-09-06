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
    # ORDER 1030-i2p8 — LOCUS-NATIVE ARTEFACT FIRST, WITHIN EACH GROUP.
    #
    # These used to try `.exe` before the ELF. Inside the tillandsias-build WSL2
    # distro on a SHARED Windows/WSL checkout both artefacts sit side by side,
    # and with WSL interop enabled the .exe RUNS there — so this probe resolved
    # the .exe while ensure_fresh_plan_binary rebuilt and touched the ELF. The
    # thing touched was not the thing resolved, the .exe stayed stale forever,
    # and every floor gate refused at `blocked:fragment-events-land:no-fresh-
    # plan-binary` without ever completing. Measured on esmeraldinha 2026-09-04:
    # gate6 exit=1 at 7m58s, after a `git pull` bumped two plan-crate source
    # mtimes past the .exe.
    #
    # REORDERING IS SAFE BECAUSE THIS IS A RUN-DON'T-STAT PROBE: it returns a
    # candidate only when that candidate's `capabilities` actually succeeds.
    # Inside a Linux distro the ELF runs and the .exe is skipped; on the Windows
    # side the ELF cannot execute and is skipped, leaving the .exe. Each locus
    # gets its native artefact without either having to know which locus it is
    # in, and no caller has to pass a flag saying so.
    #
    # The premise is currently MASKED on esmeraldinha, not absent: interop is
    # disabled in that distro today (a .exe there exits 126, `Exec format
    # error`), so the probe already falls through to the ELF. Interop is a
    # per-distro setting that can be turned back on without anyone touching this
    # repository, which is why this is fixed by ordering rather than left to the
    # environment.
    for candidate in \
        ${ctd:+"$ctd/release/tillandsias-plan"} \
        ${ctd:+"$ctd/debug/tillandsias-plan"} \
        ${ctd:+"$ctd/release/tillandsias-plan.exe"} \
        ${ctd:+"$ctd/debug/tillandsias-plan.exe"} \
        ./target/release/tillandsias-plan \
        ./target/debug/tillandsias-plan \
        ./target/release/tillandsias-plan.exe \
        ./target/debug/tillandsias-plan.exe \
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

# ── Installing a resolved binary over a canonical copy (order 1060-wxdh) ─────
#
# RUN IT BEFORE YOU INSTALL IT. resolve_plan_binary honours an explicit
# TILLANDSIAS_PLAN_BIN on EXISTENCE alone and never executes it — deliberately,
# so a stub failing the way a STALE binary fails stays distinguishable from an
# absent one. cycle-preflight then installs the resolved path over
# ~/.local/bin/tillandsias-plan so the MCP experts do not read a stale copy —
# also deliberate, also conservative. Composed, they wrote an UNVERIFIED path
# over the one binary CLAUDE.md makes the default read path for every agent on
# the host.
#
# MEASURED on yoga 2026-09-05, by causing it: a positive-control run
# `TILLANDSIAS_PLAN_BIN=<stub exiting 127> cycle-preflight` installed the stub,
# and the next `tillandsias-plan next-order` answered
# `/lib64/libm.so.6: version GLIBC_2.44 not found`. Silent, and recoverable only
# by knowing preflight writes there at all.
#
# It lives HERE rather than inline in cycle-preflight for two reasons: this file
# is already the one place that decides anything about "the plan binary", and a
# sourceable function can be pinned without running a whole preflight — which,
# under a redirected HOME, provisions an entire second builder toolbox.
#
# Never blocks: a canonical copy that stays PUT is the safe outcome, and the
# caller's contract is that a failed refresh is a report, not a refusal to start.
#
# Prints exactly one token: absent | current | refreshed |
# refresh-refused-not-runnable | refresh-failed
refresh_plan_binary_copy() {
    local src="$1" dest="$2"
    [ -e "$dest" ] || { printf 'absent
'; return 0; }
    if cmp -s "$src" "$dest"; then
        printf 'current
'
        return 0
    fi
    if ! "$src" capabilities >/dev/null 2>&1; then
        printf 'refresh-refused-not-runnable
'
        return 0
    fi
    if install -m0755 "$src" "$dest" 2>/dev/null; then
        printf 'refreshed
'
    else
        printf 'refresh-failed
'
    fi
    return 0
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

# ── Point-of-use freshness (order 851-cduu) ──────────────────────────────────
#
# resolve_plan_binary proves the artifact RUNS; it cannot prove the artifact
# matches the checkout. That gap produced two field breaches in one day
# (2026-08-23): on yolanda the Windows gate executes in WSL against a
# CARGO_TARGET_DIR cycle-preflight never rebuilds, so a 6-day-stale
# tillandsias-plan red-gated a behaviour fixture (and, run by hand, deleted
# every fragment it loaded — it predated 843-624y); on macuahuitl preflight
# built the RIGHT artifact but runs once per cycle, so sibling work pulled
# mid-cycle left check-resumable-claim-dirt.sh answering
# unattributable:plan-query-failed for 11 hours. Per-copy refresh lanes do not
# close this class: wsl-plan-expert-ensure.sh reported wsl-ok on yolanda while
# the gate's cache copy sat six days stale, because it refreshes the copy it
# knows about, not the copy the consumer resolves. A stale instrument does not
# fail; it answers wrong. So the verification happens at the POINT OF USE, in
# the locus about to consume the answer — not at cycle start, not in whichever
# locus preflight ran.
#
# ensure_fresh_plan_binary: resolve, vintage-check against the worktree, and
# when stale rebuild IN THIS LOCUS (cargo build is incremental — the fresh
# case costs a no-op; after a large merge it costs exactly the rebuild the
# consumer was missing). Contract:
#   prints path, returns 0  — resolved binary is current for this tree
#   prints nothing, returns 1 — no runnable binary (same as resolve_plan_binary)
#   prints nothing, returns 2 — binary exists but is STALE and could not be
#                               refreshed here (no cargo, or the build failed).
#                               Callers MUST refuse loudly on 2, never consume.
# A TILLANDSIAS_PLAN_BIN override passes through on existence alone, exactly
# as resolve_plan_binary treats it: the caller named the binary (litmus stubs
# depend on this), so freshness judgment would collapse the distinction
# 704-zcgi preserves.
#
# The vintage test is cargo's own model, MTIMES: git writes files at
# checkout/merge time, so any instrument source newer than the binary means
# the binary predates this tree. Deliberately NOT commit timestamps — %ct is
# stamped on the ORIGIN host hours before a merge lands here, so a commit-time
# comparison calls a pre-merge binary fresh. The source set is the crate plus
# Cargo.lock (tillandsias-plan carries no sibling path deps — workspace
# serde/serde_yaml/serde_json only; widen this set if that ever changes).
# Call from the repo root, the same working-directory contract the ./target
# candidates above already assume.
plan_binary_is_stale() {   # $1 = binary path; true when any source FILE is newer
    # -type f: directory mtimes bump on any entry add/remove (an editor temp
    # file, a scratch dir) without the build inputs changing; content lives in
    # files, which is also cargo's own fingerprint surface.
    [ -n "$(find crates/tillandsias-plan Cargo.lock -type f -newer "$1" -print -quit 2>/dev/null)" ]
}

ensure_fresh_plan_binary() {
    local bin
    if [ -n "${TILLANDSIAS_PLAN_BIN:-}" ]; then
        resolve_plan_binary
        return $?
    fi
    if ! bin="$(resolve_plan_binary)"; then
        # Nothing runnable anywhere: try to create one, then re-resolve.
        command -v cargo >/dev/null 2>&1 || return 1
        cargo build --release -p tillandsias-plan >/dev/null 2>&1 || return 1
        bin="$(resolve_plan_binary)" || return 1
    fi
    if ! plan_binary_is_stale "$bin"; then
        printf '%s\n' "$bin"
        return 0
    fi
    if command -v cargo >/dev/null 2>&1 \
        && cargo build --release -p tillandsias-plan >/dev/null 2>&1; then
        # A zero-exit build means the release artifact matches the tree by
        # cargo's own HASH-BASED fingerprints — but a no-op build never
        # touches the binary, so the mtime vintage test above can still call
        # it stale when a source file's mtime moved without its bytes (live
        # case: `git checkout -- Cargo.lock` restoring identical bytes, yoga
        # 2026-08-23, refused the gate's set-field fixture as
        # stale-plan-binary). Record cargo's verdict in the mtime domain for
        # the artifact THIS build governs; a PATH-installed binary the build
        # does not produce is deliberately not touched.
        # ORDER 1030-i2p8 — TOUCH AND SELECT THE ARTEFACT CARGO ACTUALLY
        # PRODUCED, under whichever name exists in this locus.
        #
        # This used to `touch` a path CONSTRUCTED independently of resolution
        # and then re-resolve, so on a shared checkout the touched file and the
        # resolved file could be different artefacts and the resolved one stayed
        # stale forever. The ordering fix above makes that agree in the normal
        # case; this makes it agree BY CONSTRUCTION even when it does not.
        #
        # The ELF name is tried first and the .exe second for the same
        # locus-native reason, and each candidate must still RUN before it is
        # touched — touching an artefact this cargo run did not build would
        # bless a stale binary as fresh, which is the failure this whole packet
        # is about, inverted.
        _pbp_built=""
        for _pbp_c in "${CARGO_TARGET_DIR:-target}/release/tillandsias-plan" \
                      "${CARGO_TARGET_DIR:-target}/release/tillandsias-plan.exe"; do
            [ -f "$_pbp_c" ] || continue
            "$_pbp_c" capabilities >/dev/null 2>&1 || continue
            touch "$_pbp_c" 2>/dev/null || true
            _pbp_built="$_pbp_c"
            break
        done
        if [ -n "$_pbp_built" ]; then
            bin="$_pbp_built"
        else
            bin="$(resolve_plan_binary)" || return 1
        fi
        if ! plan_binary_is_stale "$bin"; then
            printf '%s\n' "$bin"
            return 0
        fi
    fi
    return 2
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
