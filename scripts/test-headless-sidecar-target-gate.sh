#!/usr/bin/env bash
# @trace order:1269-6fcn
#
# test-headless-sidecar-target-gate.sh — the router sidecar (a LINUX musl
# container artifact) is required only when building tillandsias-headless for a
# Linux TARGET. v56.9.19.1's Windows release job died in build.rs because the
# Windows host build refused without it.
#
# HERMETIC WITH RESPECT TO THIS CHECKOUT: the sidecar is untracked, so a fresh
# detached worktree under $TMP lacks it exactly as a fresh runner does. Nothing
# in this checkout is moved or deleted; the scratch worktree is removed on exit.
#
# Arms:
#   1 WINDOWS  x86_64-pc-windows-gnu `cargo check` with the sidecar ABSENT
#              succeeds (pre-fix: rc=101, "required runtime asset missing")
#   2 LINUX    (negative control) the host Linux target with the sidecar ABSENT
#              still REFUSES with the named remedy, so the container lane can
#              never be handed an empty embed
#   3 RELEASE  the Windows job maps runner.arch to the sidecar arch and fails
#              by name when the arch-matched asset is absent
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
ok()   { printf 'ok:   %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; FAIL=1; }
skip() { printf 'skip: %s\n' "$1"; }

# ── ARM 3 first: it needs no toolchain ──────────────────────────────────────
WF="$ROOT/.github/workflows/release.yml"
wf_block="$(awk '/tillandsias-router-sidecar-\$\{sidecar_arch\}-unknown-linux-musl/ { hit = 1 } { print }' "$WF" \
    | grep -nE 'runner\.arch|sidecar_arch=|no router sidecar mapping|release has no tillandsias-router-sidecar' || true)"
if grep -q 'X64) sidecar_arch=x86_64' <<<"$wf_block" && grep -q 'ARM64) sidecar_arch=aarch64' <<<"$wf_block" \
   && grep -q 'release has no tillandsias-router-sidecar' <<<"$wf_block"; then
    ok "ARM3 the Windows job selects the sidecar by runner.arch and fails by name when it is absent"
else bad "ARM3 release.yml does not map runner.arch to the sidecar arch with a named failure"; fi

if ! command -v cargo >/dev/null 2>&1; then
    skip "ARMS 1-2 no cargo on PATH (named skip, not a pass)"
    [ "$FAIL" -eq 0 ] && { echo "PASS: headless-sidecar-target-gate (1269-6fcn, partial)"; exit 0; }
    echo "FAILED: headless-sidecar-target-gate (1269-6fcn)"; exit 1
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-gate.XXXXXX")"
wt="$scratch/wt"
cleanup() { git -C "$ROOT" worktree remove --force "$wt" >/dev/null 2>&1; rm -rf "$scratch"; }
trap cleanup EXIT
git -C "$ROOT" worktree add -q --detach "$wt" HEAD 2>/dev/null || { bad "could not create a scratch worktree"; exit 1; }
# Carry this tree's uncommitted build.rs, so the fixture tests what is on disk.
cp "$ROOT/crates/tillandsias-headless/build.rs" "$wt/crates/tillandsias-headless/build.rs"
[ ! -e "$wt/images/router/tillandsias-router-sidecar" ] || { bad "scratch worktree unexpectedly has a sidecar"; exit 1; }
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"

# ── ARM 1 ────────────────────────────────────────────────────────────────
# "Target installed" is not "target buildable" (yolanda 2026-09-29): ring's
# build script compiles C, so a host with the rustup target but no MinGW C
# compiler fails in ring, which says nothing about this build.rs. Probe the
# compiler, and judge ONLY on the sidecar panic: any other failure is a named
# toolchain skip, never a pass and never this gate's failure.
if ! rustup target list --installed 2>/dev/null | grep -qx x86_64-pc-windows-gnu; then
    skip "ARM1 target x86_64-pc-windows-gnu not installed (named skip, not a pass)"
elif ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    skip "ARM1 no x86_64-w64-mingw32-gcc: C dependencies (ring) cannot build for the target here (named skip, not a pass)"
else
    out1="$(cd "$wt" && cargo check -q -p tillandsias-headless --bin tillandsias --target x86_64-pc-windows-gnu 2>&1)"; rc1=$?
    if [ "$rc1" -eq 0 ]; then
        ok "ARM1 a Windows-target check succeeds with the sidecar absent"
    elif grep -q 'required runtime asset missing' <<<"$out1"; then
        bad "ARM1 a Windows-target build refuses for want of the Linux-only sidecar: $(grep -m1 'required runtime asset missing' <<<"$out1")"
    else
        skip "ARM1 the target toolchain failed before build.rs could be judged: $(grep -m1 -E '^error' <<<"$out1") (named skip, not a pass)"
    fi
fi

# ── ARM 2 ────────────────────────────────────────────────────────────────
# The negative control needs a LINUX host target: on a Windows or macOS host
# the host build is itself non-Linux and correctly does not refuse.
host_triple="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')"
case "$host_triple" in
    *-linux-*)
        out2="$(cd "$wt" && cargo check -q -p tillandsias-headless --bin tillandsias 2>&1)"; rc2=$?
        if [ "$rc2" -ne 0 ] && grep -q 'required runtime asset missing' <<<"$out2" \
           && grep -q 'BUILD ARTIFACT' <<<"$out2"; then
            ok "ARM2 negative control: a Linux-target build still refuses without the sidecar, naming the remedy"
        else bad "ARM2 Linux target rc=$rc2 did not refuse by name"; fi ;;
    *) skip "ARM2 host target is ${host_triple:-unknown}, not Linux: the Linux refusal cannot be exercised here (named skip, not a pass)" ;;
esac

[ "$FAIL" -eq 0 ] && { echo "PASS: headless-sidecar-target-gate (1269-6fcn)"; exit 0; }
echo "FAILED: headless-sidecar-target-gate (1269-6fcn)"; exit 1
