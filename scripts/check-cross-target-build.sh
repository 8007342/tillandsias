#!/usr/bin/env bash
# @trace spec:ci-release
#
# check-cross-target-build.sh — ORDER 656-spux.
#
# THE GAP THIS CLOSES. Every host compiles for ITSELF and nothing else, so
# platform-gated code is verified by exactly the platform that cannot exercise
# the other arms. `./build.sh --check` validates the ledger, traces and YAML; it
# does not build the workspace for another target. A cfg-gated defect is
# therefore invisible from the host most likely to introduce it — 653-7rag was
# introduced by a Linux host repairing macOS-only lints and reached Windows.
#
# IT WAS NOT HYPOTHETICAL WHEN THIS SCRIPT WAS WRITTEN. The first run against
# x86_64-pc-windows-gnu failed on linux-next:
#
#   error[E0425]: cannot find function `enforce_ca_key_mode` in this scope
#     note: found an item that was configured out
#
# — a `#[cfg(unix)]` definition with three unguarded callers and no fallback
# arm, sitting on trunk, invisible to every host's gate. Same shape as
# 653-7rag, found in the first minute of looking. Fixed in the same commit.
#
# VERDICT GRAMMAR, one line on stdout:
#   ok:cross-target:<target>            the workspace checks clean for <target>
#   fail:cross-target:<target>          it does not — exit 1
#   skip:cross-target:<reason>          this host cannot run it — exit 0
#
# SKIPPING IS NOT FAILING, deliberately. The check needs a rustup std for the
# target AND a C cross-toolchain (ring's build script wants
# x86_64-w64-mingw32-gcc). Neither is on a stock host, and 115 MiB of mingw is
# not something to force onto every machine in the fleet as a side effect of a
# lint. So a host that lacks either says so and exits 0; a host that has them
# gets a real gate. Enable on a Fedora/toolbox host with:
#
#   rustup target add x86_64-pc-windows-gnu
#   sudo dnf install -y mingw64-gcc
#
# MEASURED on lenovinha (Silverblue, inside tillandsias-builder). The recurring
# cost is the number that matters and it is almost nothing:
#
#   steady-state, inside ./build.sh --check      0.3s
#   first run after the target is installed      ~37s  (one-off: cargo compiles
#                                                      every dependency for the
#                                                      new target once)
#   rustup target add x86_64-pc-windows-gnu      2.8s
#   mingw64-gcc                                  33 MiB down / 115 MiB installed
#
# The 37s figure was originally recorded here as the WARM cost, which overstated
# the recurring price by two orders of magnitude — it was the first run after a
# cold dependency build, not steady state. Corrected 2026-08-24 after profiling
# the phase directly (TILLANDSIAS_GATE_PROFILE=1). It matters because the cost
# was the whole argument for leaving this opt-in: a check that adds 0.3s to
# every gate is a very different proposition from one that adds 37s.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

TARGET="${TILLANDSIAS_CROSS_TARGET:-x86_64-pc-windows-gnu}"

# The C cross-compiler each target needs for native build scripts. Keyed by
# target so a second target does not have to re-derive the mapping.
case "$TARGET" in
    x86_64-pc-windows-gnu)  CC_TOOL=x86_64-w64-mingw32-gcc ;;
    aarch64-pc-windows-gnu) CC_TOOL=aarch64-w64-mingw32-gcc ;;
    *)                      CC_TOOL="" ;;
esac

if ! command -v cargo >/dev/null 2>&1; then
    echo "skip:cross-target:no-cargo"
    exit 0
fi

if ! rustup target list --installed 2>/dev/null | grep -qxF "$TARGET"; then
    echo "skip:cross-target:target-not-installed:$TARGET"
    exit 0
fi

if [ -n "$CC_TOOL" ] && ! command -v "$CC_TOOL" >/dev/null 2>&1; then
    # Named explicitly rather than as a generic "toolchain missing": the fix is
    # one dnf install, and a reader who is told WHICH binary is absent does not
    # have to reproduce the ring build failure to find out.
    echo "skip:cross-target:no-c-toolchain:$CC_TOOL"
    exit 0
fi

if out="$(cargo check --workspace --target "$TARGET" 2>&1)"; then
    echo "ok:cross-target:$TARGET"
    exit 0
fi

echo "fail:cross-target:$TARGET"
# Only the errors: a full cargo log buries the three lines that matter.
printf '%s\n' "$out" | grep -E "^error|^  --> |configured out|could not compile" | head -40 >&2
exit 1
