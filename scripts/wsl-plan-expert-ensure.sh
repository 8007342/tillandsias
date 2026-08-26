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
# Dual-lane, one file:
#   inner (inside the distro)  build + install + capabilities-verify
#   outer (Windows Git Bash)   re-exec the inner lane through wsl.exe
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

# ── Outer lane: Windows host shell ─────────────────────────────────────────
case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) : ;;
    *)
        echo "skip:not-windows"
        exit 0
        ;;
esac
command -v wsl.exe >/dev/null 2>&1 || { echo "skip:no-wsl"; exit 0; }
distro="${TILLANDSIAS_WSL_BUILD_DISTRO:-tillandsias-build}"
# wsl.exe emits UTF-16LE; strip NULs and CRs before matching.
if ! wsl.exe -l -q 2>/dev/null | tr -d '\0\r' | grep -qx "$distro"; then # sigpipe-ok: safe pipeline
    echo "skip:no-build-distro"
    exit 0
fi
repo_msys="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Git Bash /c/... is the distro's /mnt/c/... under default WSL mounts.
repo_wsl="/mnt${repo_msys}"
verdict="$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    wsl.exe -d "$distro" -- bash -lc "bash '$repo_wsl/scripts/wsl-plan-expert-ensure.sh' inner" 2>/dev/null \
    | tr -d '\0\r' | tail -1)"
case "$verdict" in
    ok:wsl-plan-expert:* | degraded:* | skip:*) printf '%s\n' "$verdict" ;;
    *) echo "degraded:wsl-invoke-failed" ;;
esac
exit 0
