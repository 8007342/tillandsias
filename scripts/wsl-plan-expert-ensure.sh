#!/usr/bin/env bash
# @trace order:770-ehym
#
# Ensure the WSL-side MCP expert binary exists on a path the WINDOWS lifecycle
# cannot touch. Order 770-ehym; evidence trail in
# plan/issues/windows-host-tooling-hits-linux-elves-in-target-2026-08-16.md.
#
# THE COLLISION THIS BREAKS. On a shared Windows/WSL checkout, the two
# toolchain lifecycles fought over ONE artifact path,
# ./target/release/tillandsias-plan: the WSL-side MCP servers exec'd the Linux
# ELF there, the Windows daily cache sweep deleted it (target/ is the sweep's
# whole mandate), and the next Windows preflight rebuilt only the PE — so
# every forge-plan/project-info TOOL CALL died at exec time for a full cycle
# while the handshake-only health probe kept saying ok:experts-healthy
# (2026-08-16, cycles 1-2). Disjoint paths make that sequence structurally
# impossible: the WSL expert binary is built into a WSL-LOCAL
# CARGO_TARGET_DIR (ext4, never under the shared /mnt/c target/) and
# installed to ~/.local/bin/tillandsias-plan inside the distro — which is
# already PLAN_BIN_CANONICAL, the wrappers' first fallback candidate.
#
# Inner lane only (inside the distro): build + install + capabilities-verify.
# The outer lane (Windows Git Bash re-exec through wsl.exe) is
# scripts/lua/wsl-plan-expert-ensure.lua (2421-7wvs).
#
# GRAMMAR (exactly one line on stdout; always exit 0 — this is advisory, the
# deterministic direct-binary fallback keeps a cycle alive without experts):
#   ok:wsl-plan-expert:<installed-path>
#   skip:(not-windows|no-wsl|no-build-distro)
#   degraded:(no-cargo-in-distro|wsl-build-failed|install-failed|capabilities-refused|wsl-invoke-failed|cannot-cd-repo)
set -uo pipefail

# ── Inner lane: we are inside a WSL distro ─────────────────────────────────
if [ -n "${WSL_DISTRO_NAME:-}" ] || [ "${1:-}" = "inner" ]; then
    repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || repo=""
    [ -n "$repo" ] && cd "$repo" 2>/dev/null || { echo "degraded:cannot-cd-repo"; exit 0; }
    command -v cargo >/dev/null 2>&1 || { echo "degraded:no-cargo-in-distro"; exit 0; }
    # WSL-local by contract: never the shared checkout target/ (the collision).
    export CARGO_TARGET_DIR="${TILLANDSIAS_WSL_PLAN_TARGET:-$HOME/.cache/tillandsias-wsl-target}"
    mkdir -p "$HOME/.local/bin" "$CARGO_TARGET_DIR" 2>/dev/null || true
    if ! cargo build --release -p tillandsias-plan >/dev/null 2>&1; then
        echo "degraded:wsl-build-failed"
        exit 0
    fi
    if ! install -m0755 "$CARGO_TARGET_DIR/release/tillandsias-plan" \
        "$HOME/.local/bin/tillandsias-plan" 2>/dev/null; then
        echo "degraded:install-failed"
        exit 0
    fi
    # Prove the installed artifact answers (721-nyev: running is evidence).
    if "$HOME/.local/bin/tillandsias-plan" capabilities >/dev/null 2>&1; then
        echo "ok:wsl-plan-expert:$HOME/.local/bin/tillandsias-plan"
    else
        echo "degraded:capabilities-refused"
    fi
    exit 0
fi

# ── Outer lane: ported to scripts/lua/wsl-plan-expert-ensure.lua (2421-7wvs) ──
# The Windows-host side (find the build distro, re-exec this file's inner lane
# through wsl.exe) is Lua now. This file keeps only the inner lane, which runs
# INSIDE the guest, where no Lua runner exists until 2420-rd7x.
echo "degraded:outer-lane-is-lua — run: tillandsias-plan script run scripts/lua/wsl-plan-expert-ensure.lua"
exit 0
