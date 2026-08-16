#!/usr/bin/env bash
# =============================================================================
# ensure_toolbox.sh — the DEFAULT include for every repo script
# (operator directive 2026-08-16: "use toolboxes for everything; scripts should
# be idempotent and toolbox friendly — a mere shebang-level include of
# ensure_toolbox.sh, which shall do 'if toolbox doesn't exist, create and
# init, otherwise noop'").
#
# Usage, from any script in scripts/:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/ensure_toolbox.sh"
#
# Contract:
#   * After this returns 0, `toolbox run --container tillandsias-builder …`
#     works on toolbox-capable hosts (Silverblue / rpm-ostree).
#   * On hosts without `toolbox` (mutable Fedora, macOS, Windows/WSL) it is a
#     silent, instant noop — the script keeps using host tools as before.
#   * IDEMPOTENT: create+init happens at most once (marker-gated); every later
#     call is a cheap existence check.
#   * It deliberately does NOT re-exec the caller into the toolbox and does
#     NOT rewrite the caller's shell options. The stronger re-exec behavior
#     stays in with-tillandsias-builder.sh for build entry points.
#
# Delegation, not duplication: the create/init logic (and its idempotence
# markers, proxy neutralization, and toolchain set) lives in
# with-tillandsias-builder.sh. Running that wrapper in DIRECT mode with `true`
# performs exactly "ensure the toolbox, then noop" — one implementation, two
# entry shapes. A tool missing on the host (nix, ruby, …) is then reachable as
# `toolbox run --container tillandsias-builder <tool> …` instead of a host
# daemon/package ask (the nix-daemon lesson, 2026-08-16).
# =============================================================================

_ENSURE_TOOLBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v toolbox >/dev/null 2>&1; then
    if ! "$_ENSURE_TOOLBOX_DIR/with-tillandsias-builder.sh" true; then
        echo "[ensure_toolbox] ERROR: toolbox ensure failed (with-tillandsias-builder.sh true)" >&2
        unset _ENSURE_TOOLBOX_DIR
        return 1 2>/dev/null || exit 1
    fi
fi
unset _ENSURE_TOOLBOX_DIR
return 0 2>/dev/null || exit 0
