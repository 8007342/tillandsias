#!/usr/bin/env bash
# =============================================================================
# with-tillandsias-builder.sh — Transparent toolbox re-exec for Silverblue
#
# Detects whether this host is Fedora Silverblue (immutable). If so, checks
# whether the current process is already inside the `tillandsias-builder`
# toolbox. If not, creates the toolbox (idempotent), initializes it with
# required build tools (idempotent), and re-execs the calling command inside
# the toolbox — all transparently.
#
# Source this at the very top of any build/CI entry point that needs
# Rust/gcc/ruby etc:
#
#   source "$(dirname "$0")/scripts/with-tillandsias-builder.sh"
#
# Or run standalone:
#
#   scripts/with-tillandsias-builder.sh ./build.sh --check
#
# Non-Silverblue hosts (Workstation, macOS, Windows) pass through with zero
# overhead.
#
# Environment:
#   TILLANDSIAS_SKIP_TOOLBOX=1  — force skip, run bare on host
# =============================================================================

set -euo pipefail

SELF="${BASH_SOURCE[0]}"
TOOLBOX_NAME="${TILLANDSIAS_BUILDER_TOOLBOX:-tillandsias-builder}"
MARKER_FILE="$HOME/.cache/tillandsias/builder-toolbox-initialized"

# Direct invocation (`scripts/with-tillandsias-builder.sh <cmd> [args...]`)
# runs <cmd> in the build environment; sourced invocation re-execs the calling
# script inside the toolbox. Every skip-guard below must therefore run the
# command for the direct case instead of silently returning — a bare
# `return 0 || exit 0` turns a direct call into a no-op that lies with exit 0.
_TB_DIRECT=0
[[ "${BASH_SOURCE[0]}" == "$0" ]] && _TB_DIRECT=1

# ── Guard: skip if already inside the builder toolbox ─────────────────────
if [[ -n "${TOOLBOX_PATH:-}" ]]; then
    [[ "$_TB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    return 0 2>/dev/null || exit 0
fi

# ── Guard: skip inside any OCI/container runtime ──────────────────────────
if [[ "${container:-}" == "oci" ]] || [[ "${container:-}" == "podman" ]]; then
    [[ "$_TB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    return 0 2>/dev/null || exit 0
fi

# ── Guard: explicit skip ─────────────────────────────────────────────────
if [[ "${TILLANDSIAS_SKIP_TOOLBOX:-}" == "1" ]]; then
    [[ "$_TB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    return 0 2>/dev/null || exit 0
fi

# ── Guard: only trigger on Silverblue / rpm-ostree hosts ──────────────────
if [[ ! -f /etc/os-release ]]; then
    [[ "$_TB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    return 0 2>/dev/null || exit 0
fi

VARIANT_ID="$(grep -oP '^VARIANT_ID=\K.*' /etc/os-release 2>/dev/null || true)"
if [[ "$VARIANT_ID" != "silverblue" ]] && ! command -v rpm-ostree &>/dev/null; then
    [[ "$_TB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    return 0 2>/dev/null || exit 0
fi

# ── Guard: toolbox binary must be installed ──────────────────────────────
if ! command -v toolbox &>/dev/null; then
    echo "[tillandsias-builder] ERROR: 'toolbox' not found on Silverblue." >&2
    echo "[tillandsias-builder] Install it:" >&2
    echo "    rpm-ostree install toolbox" >&2
    echo "    (or: sudo dnf install --skip-broken toolbox)" >&2
    echo "[tillandsias-builder] Then reboot and retry." >&2
    exit 1
fi

# ── Neutralize enclave-only proxy env for host podman operations ─────────
# tillandsias --init writes an enclave-only proxy (http://proxy:3128) into
# ~/.config/containers/containers.conf [engine] env; podman injects those vars
# into its own image pulls and every container it launches. That hostname only
# resolves inside enclave pod networks, so on the host it poisons the
# `toolbox create` image pull and dnf/rustup/cargo inside the builder toolbox
# (plan/issues/podman-proxy-reset-chicken-and-egg-2026-07-08.md). An empty
# value set in the spawning environment overrides [engine] env — the same
# pattern as BUILD_PROXY_NEUTRALIZE_VARS in tillandsias-headless. A proxy var
# the operator really set stays untouched.
for _proxy_var in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY; do
    if [[ -z "${!_proxy_var+x}" ]]; then
        export "$_proxy_var="
    fi
done
unset _proxy_var

# ── Helper: exact-match the CONTAINER NAME column (list output is columned,
#    so a whole-line grep -x can never match) ──────────────────────────────
_toolbox_exists() {
    toolbox list --containers 2>/dev/null | awk 'NR > 1 { print $2 }' | grep -qxF "$TOOLBOX_NAME"
}

# ── Helper: rustup installed inside the toolbox ──────────────────────────
_toolbox_has_rustup() {
    toolbox run --container "$TOOLBOX_NAME" command -v rustup &>/dev/null 2>&1
}

# ── Ensure toolbox exists and is initialized ──────────────────────────────
if ! _toolbox_exists; then
    echo "[tillandsias-builder] Creating '$TOOLBOX_NAME' toolbox (first run)..."
    # --assumeyes: a pristine host has no fedora-toolbox image cached, and a
    # non-interactive `toolbox create` refuses to download it without consent.
    toolbox create --assumeyes --container "$TOOLBOX_NAME"
fi

if ! _toolbox_has_rustup; then
    echo "[tillandsias-builder] Initializing '$TOOLBOX_NAME' with build tools..."

    toolbox run --container "$TOOLBOX_NAME" \
        sudo dnf install -y \
            gcc pkg-config file cmake make \
            openssl-devel systemd-devel \
            ruby perl-FindBin \
            procps-ng findutils diffutils \
        2>&1 | while IFS= read -r line; do printf '  [dnf] %s\n' "$line"; done

    RUSTUP_INIT="$HOME/.cache/tillandsias/rustup-init.sh"
    mkdir -p "$(dirname "$RUSTUP_INIT")"
    if [[ ! -f "$RUSTUP_INIT" ]]; then
        curl --proto '=https' --tlsv1.2 -sSf \
            https://sh.rustup.rs -o "$RUSTUP_INIT"
        chmod +x "$RUSTUP_INIT"
    fi

    toolbox run --container "$TOOLBOX_NAME" \
        bash "$RUSTUP_INIT" -y 2>&1 | while IFS= read -r line; do printf '  [rustup] %s\n' "$line"; done

    toolbox run --container "$TOOLBOX_NAME" \
        bash -l -c "rustup target add x86_64-unknown-linux-musl aarch64-unknown-linux-musl" \
        2>&1 | while IFS= read -r line; do printf '  [rustup] %s\n' "$line"; done

    toolbox run --container "$TOOLBOX_NAME" \
        bash -c "mkdir -p '$(dirname "$MARKER_FILE")' && touch '$MARKER_FILE'"

    echo "[tillandsias-builder] Initialization complete."
fi

# ── Re-exec inside the toolbox ────────────────────────────────────────────
# At this point we are on the host (not in toolbox). Re-exec the current
# command inside the toolbox.

# Escape arguments for safe insertion into bash -c string
ARGS_QUOTED=""
for arg in "$@"; do
    ARGS_QUOTED="$ARGS_QUOTED$(printf '%q ' "$arg")"
done
PWD_QUOTED="$(printf '%q' "$(pwd)")"

echo "[tillandsias-builder] Re-execing inside '$TOOLBOX_NAME' toolbox..."

if [[ "$_TB_DIRECT" == 1 ]]; then
    # Direct execution: `scripts/with-tillandsias-builder.sh <cmd> [args...]`
    # runs <cmd> itself inside the toolbox. (The previous BASH_SOURCE walk
    # could only ever find this file, fell back to build.sh, and re-ran it
    # with the command line as bogus arguments.)
    if [[ $# -eq 0 ]]; then
        echo "usage: $SELF <command> [args...]" >&2
        exit 2
    fi
    exec toolbox run --container "$TOOLBOX_NAME" \
        bash -l -c "export TILLANDSIAS_SKIP_TOOLBOX=1 ; cd $PWD_QUOTED && exec $ARGS_QUOTED"
fi

# Sourced from a build script: when `source`d, $0 and $@ are the calling
# script and its original arguments — re-exec that script inside the toolbox.
SCRIPT="$0"
if [[ "$SCRIPT" != /* ]]; then
    SCRIPT="$(pwd)/$SCRIPT"
fi
exec toolbox run --container "$TOOLBOX_NAME" \
    bash -l -c "export TILLANDSIAS_SKIP_TOOLBOX=1 ; cd $PWD_QUOTED && exec bash $(printf '%q' "$SCRIPT") $ARGS_QUOTED"
