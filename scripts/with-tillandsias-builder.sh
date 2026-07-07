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

# ── Guard: skip if already inside the builder toolbox ─────────────────────
if [[ -n "${TOOLBOX_PATH:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi

# ── Guard: skip inside any OCI/container runtime ──────────────────────────
if [[ "${container:-}" == "oci" ]] || [[ "${container:-}" == "podman" ]]; then
    return 0 2>/dev/null || exit 0
fi

# ── Guard: explicit skip ─────────────────────────────────────────────────
if [[ "${TILLANDSIAS_SKIP_TOOLBOX:-}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# ── Guard: only trigger on Silverblue / rpm-ostree hosts ──────────────────
if [[ ! -f /etc/os-release ]]; then
    return 0 2>/dev/null || exit 0
fi

VARIANT_ID="$(grep -oP '^VARIANT_ID=\K.*' /etc/os-release 2>/dev/null || true)"
if [[ "$VARIANT_ID" != "silverblue" ]] && ! command -v rpm-ostree &>/dev/null; then
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

# ── Helper: toolbox list returns the name only if present ────────────────
_toolbox_exists() {
    toolbox list --containers 2>/dev/null | grep -qxF "$TOOLBOX_NAME"
}

# ── Helper: rustup installed inside the toolbox ──────────────────────────
_toolbox_has_rustup() {
    toolbox run --container "$TOOLBOX_NAME" command -v rustup &>/dev/null 2>&1
}

# ── Ensure toolbox exists and is initialized ──────────────────────────────
if ! _toolbox_exists; then
    echo "[tillandsias-builder] Creating '$TOOLBOX_NAME' toolbox (first run)..."
    toolbox create --container "$TOOLBOX_NAME"
fi

if ! _toolbox_has_rustup; then
    echo "[tillandsias-builder] Initializing '$TOOLBOX_NAME' with build tools..."

    toolbox run --container "$TOOLBOX_NAME" \
        sudo dnf install -y \
            gcc pkg-config file cmake make \
            openssl-devel systemd-devel \
            ruby perl-FindBin \
            python3 python3-pyyaml \
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

SCRIPT=""
if [[ "$0" == *"$SELF"* ]] || [[ "$0" == bash ]] || [[ "$0" == */bash ]]; then
    # Direct execution — use BASH_SOURCE to find our caller
    for ((i = 0; i < ${#BASH_SOURCE[@]}; i++)); do
        src="${BASH_SOURCE[$i]}"
        if [[ "$src" != *"$SELF"* ]] && [[ -x "$src" ]] || [[ "$src" != *"$SELF"* && "$src" == *.sh ]]; then
            SCRIPT="$src"
            break
        fi
    done
    if [[ -z "$SCRIPT" ]]; then
        SCRIPT="${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}"
    fi
else
    # Sourced inside a script — $0 is the caller
    SCRIPT="$0"
fi

# Ensure we're at the repo root (relative $0 is relative to CWD)
if [[ "$SCRIPT" != /* ]]; then
    SCRIPT="$(pwd)/$SCRIPT"
fi
if [[ ! -f "$SCRIPT" ]]; then
    SCRIPT="$(cd "$(dirname "$SELF")/.." && pwd)/build.sh"
fi

# Escape arguments for safe insertion into bash -c string
ARGS_QUOTED=""
for arg in "$@"; do
    ARGS_QUOTED="$ARGS_QUOTED$(printf '%q ' "$arg")"
done
PWD_QUOTED="$(printf '%q' "$(pwd)")"

echo "[tillandsias-builder] Re-execing inside '$TOOLBOX_NAME' toolbox..."
exec toolbox run --container "$TOOLBOX_NAME" \
    bash -l -c "export TILLANDSIAS_SKIP_TOOLBOX=1 ; cd $PWD_QUOTED && exec bash '$SCRIPT' $ARGS_QUOTED"
