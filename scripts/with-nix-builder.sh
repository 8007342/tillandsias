#!/usr/bin/env bash
# with-nix-builder.sh — transparent nix-in-container re-exec for crane builds
#
# When NIX_BUILD_LANE=container is set, routes nix builds through a throwaway
# container with nix installed, backed by the persistent host nix store and
# the enclave binary cache. Non-Linux hosts and NIX_BUILD_LANE != container
# pass through with zero overhead.
#
# Usage (direct):
#   scripts/with-nix-builder.sh nix build .#tillandsias-x86_64-musl
#
# Usage (sourced — re-execs the calling script):
#   source scripts/with-nix-builder.sh
#
# The container mounts:
#   - ~/.local/share/tillandsias/nix-store → /host-store (persistent nix store)
#   - $REPO_ROOT → /work (source tree)
#   - /tmp/tillandsias-ca → /tmp/tillandsias-ca:ro (TLS CA for enclave cache)
#
# Store path: /host-store (NOT /nix/store — the container's /nix holds the nix
# installation; the host store is a separate mount accessed via --store flag).

set -euo pipefail

SELF="${BASH_SOURCE[0]}"
CONTAINER_NAME="${TILLANDSIAS_NIX_BUILDER_CONTAINER:-tillandsias-nix-builder}"
IMAGE_NAME="${TILLANDSIAS_NIX_BUILDER_IMAGE:-tillandsias-nix-builder}"
CHROOT_STORE="${TILLANDSIAS_NIX_CHROOT_STORE:-$HOME/.local/share/tillandsias/nix-store}"
CA_DIR="${TILLANDSIAS_CA_DIR:-/tmp/tillandsias-ca}"
NIX_CACHE_SCRIPT="${TILLANDSIAS_NIX_CACHE_SCRIPT:-$(cd "$(dirname "${SELF}")" && pwd)/nix-cache-service.sh}"
REPO_ROOT="$(cd "$(dirname "${SELF}")/.." && pwd)"

# Direct invocation runs the given command; sourced invocation re-execs caller.
_NB_DIRECT=0
[[ "${BASH_SOURCE[0]}" == "$0" ]] && _NB_DIRECT=1

# ── Guard: skip if NIX_BUILD_LANE is not container ────────────────────────
if [[ "${NIX_BUILD_LANE:-}" != "container" ]]; then
    [[ "$_NB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    return 0 2>/dev/null || exit 0
fi

# ── Guard: skip inside any OCI/container runtime ──────────────────────────
if [[ "${container:-}" == "oci" ]] || [[ "${container:-}" == "podman" ]]; then
    [[ "$_NB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    return 0 2>/dev/null || exit 0
fi

# ── Guard: skip on non-Linux ──────────────────────────────────────────────
if [[ "$(uname -s)" != "Linux" ]]; then
    [[ "$_NB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    return 0 2>/dev/null || exit 0
fi

# ── Guard: require podman ─────────────────────────────────────────────────
if ! command -v podman &>/dev/null; then
    echo "[nix-builder] FATAL: podman is required for NIX_BUILD_LANE=container" >&2
    exit 1
fi

# ── Neutralize enclave proxy for podman operations ────────────────────────
if [[ -f "$(dirname "${SELF}")/podman-neutralize-proxy.sh" ]]; then
    source "$(dirname "${SELF}")/podman-neutralize-proxy.sh"
fi

# ── Ensure the builder image exists (idempotent) ──────────────────────────
_nix_builder_image_exists() {
    podman image exists "$IMAGE_NAME" 2>/dev/null
}

_nix_builder_ensure_image() {
    if _nix_builder_image_exists; then
        return 0
    fi
    local containerfile
    containerfile="$(dirname "${SELF}")/../nix/builder/Containerfile"
    if [[ ! -f "$containerfile" ]]; then
        echo "[nix-builder] FATAL: Containerfile not found at $containerfile" >&2
        return 1
    fi
    echo "[nix-builder] Building '$IMAGE_NAME' image (first run)..."
    podman build -t "$IMAGE_NAME" -f "$containerfile" "$(dirname "$containerfile")" \
        2>&1 | while IFS= read -r line; do printf '  [build] %s\n' "$line"; done
}

# ── Get substituter args from nix-cache-service.sh ────────────────────────
_nix_builder_substituter_args() {
    if [[ -x "$NIX_CACHE_SCRIPT" ]]; then
        "$NIX_CACHE_SCRIPT" substituter-args 2>/dev/null || true
    fi
}

# ── Container running? ────────────────────────────────────────────────────
_nix_builder_running() {
    [[ "$(podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == "true" ]]
}

# ── Ensure persistent nix store exists ────────────────────────────────────
_nix_builder_ensure_store() {
    mkdir -p "$CHROOT_STORE" 2>/dev/null || return 1
    [ -d "$CHROOT_STORE/nix/store" ] || return 0  # empty is fine, will populate
}

# ── Build the podman run args ─────────────────────────────────────────────
_nix_builder_run_args() {
    # Substitute args from the cache service (may be empty if cache is down)
    local sub_args
    sub_args="$(_nix_builder_substituter_args)"

    # Common podman args: privileged, network host, read-write store
    local -a args=(
        --rm
        --name "$CONTAINER_NAME"
        --privileged
        --network host
        --security-opt label=disable
        -v "$CHROOT_STORE:/host-store"
        -v "$REPO_ROOT:/work"
    )

    # Mount TLS CA if present
    if [[ -d "$CA_DIR" ]]; then
        args+=(-v "$CA_DIR:/tmp/tillandsias-ca:ro")
    fi

    # Forward TILLANDSIAS_* env vars
    while IFS= read -r _nb_var; do
        args+=(-e "$_nb_var=${!_nb_var}")
    done < <(compgen -v | grep '^TILLANDSIAS_' || true)

    # Add NIX_BUILD_LANE so the container knows it's in the builder
    args+=(-e "NIX_BUILD_LANE=container")
    args+=(-e "container=podman")

    # Neutralize the enclave-only proxy that containers.conf injects into every
    # container. GitHub downloads fail with SSL mismatches when the proxy
    # intercepts TLS. Empty values override [engine] env (same pattern as
    # podman-neutralize-proxy.sh).
    for _nb_pv in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
        args+=(-e "$_nb_pv=")
    done

    printf '%s\n' "${args[@]}"
}

# ── Main: exec inside the builder container ───────────────────────────────
_nix_builder_exec() {
    _nix_builder_ensure_store || { echo "[nix-builder] FATAL: cannot create nix store" >&2; return 1; }
    _nix_builder_ensure_image || { echo "[nix-builder] FATAL: cannot build image" >&2; return 1; }

    # Escape the command for bash -c
    local CMD_QUOTED=""
    for arg in "$@"; do
        CMD_QUOTED="$CMD_QUOTED$(printf '%q ' "$arg")"
    done

    local -a run_args=()
    while IFS= read -r _nb_line; do
        run_args+=("$_nb_line")
    done < <(_nix_builder_run_args)

    echo "[nix-builder] Execing inside '$CONTAINER_NAME' container..."

    # Wrap the command to truly UNSET proxy env vars (empty string is not
    # enough — nix's bundled libcurl interprets http_proxy="" as "use proxy
    # at empty host" whereas unset means "no proxy at all").
    local _PROXY_UNSET="unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY 2>/dev/null;"

    exec podman run "${run_args[@]}" \
        "$IMAGE_NAME" \
        -c "cd /work && $_PROXY_UNSET $CMD_QUOTED"
}

# ── Detect nix build commands and route to nix-build-container.sh ──────────
_nix_builder_is_nix_build() {
    [[ "${1:-}" == "nix" ]] || return 1
    shift
    # Skip flags (--extra-experimental-features, etc.)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --*) shift ;;
            build) return 0 ;;
            flake) shift ;;  # `nix flake` commands may also need pre-fetch
            *) return 1 ;;
        esac
    done
    return 1
}

# ── Entry point ───────────────────────────────────────────────────────────
_nb_entry() {
    if [[ $# -eq 0 ]]; then
        echo "usage: $SELF <command> [args...]" >&2
        echo "  NIX_BUILD_LANE=container must be set." >&2
        exit 2
    fi

    # Route nix build commands through the pre-fetch wrapper
    if _nix_builder_is_nix_build "$@"; then
        local nix_build_script
        nix_build_script="$(dirname "${SELF}")/nix-build-container.sh"
        if [[ -x "$nix_build_script" ]]; then
            local -a build_args=()
            local past_build=0
            local arg
            for arg in "$@"; do
                if [[ $past_build -eq 1 ]]; then
                    build_args+=("$arg")
                elif [[ "$arg" == "build" ]]; then
                    past_build=1
                fi
            done
            _nix_builder_exec bash "$(printf '%q' "$nix_build_script")" "${build_args[@]}"
        fi
    fi

    _nix_builder_exec "$@"
}

if [[ "$_NB_DIRECT" == 1 ]]; then
    _nb_entry "$@"
else
    SCRIPT="$0"
    if [[ "$SCRIPT" != /* ]]; then
        SCRIPT="$(pwd)/$SCRIPT"
    fi
    _nix_builder_exec bash "$(printf '%q' "$SCRIPT")" "$@"
fi
