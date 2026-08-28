#!/usr/bin/env bash
# with-nix-builder.sh — transparent nix-in-container re-exec for crane builds
#
# When NIX_BUILD_LANE=container is set, routes nix builds through a throwaway
# container with nix installed, backed by the persistent host nix store.
# Non-Linux hosts and NIX_BUILD_LANE != container pass through with zero
# overhead.
#
# THE LANE SERVES NIX INVOCATIONS ONLY. The builder image carries nix, bash,
# curl, and jq — no cargo, no host toolchain — so it cannot run build.sh or
# arbitrary build commands; those fail loudly below instead of exec-ing into
# a container that cannot run them. Enclave-binary-cache substituter wiring
# is NOT plumbed through this wrapper: the flags nix-cache-service.sh emits
# name host paths that are meaningless inside the container. Teaching the
# lane to substitute from the enclave cache is 873-b1nx/790-6n2k work.
#
# Usage (direct):
#   scripts/with-nix-builder.sh nix build .#tillandsias-x86_64-musl
#
# Usage (sourced — e.g. from build.sh): with NIX_BUILD_LANE unset this is a
# zero-overhead pass-through. With NIX_BUILD_LANE=container set, a sourced
# caller is a whole script — never a nix invocation the image can serve — so
# the sourced path fails loudly rather than exec-ing a doomed container.
#
# The container mounts:
#   - ~/.local/share/tillandsias/nix-store → /host-store (persistent nix store)
#   - $REPO_ROOT → /work (source tree)
#   - /tmp/tillandsias-ca → /tmp/tillandsias-ca:ro (stack TLS CA, when present)
#
# Store path: /host-store (NOT /nix/store — the container's /nix holds the nix
# installation; the host store is a separate mount accessed via --store flag).

# `source` runs in the CALLER's shell, so these options would otherwise rewrite
# the sourcer's error handling permanently — the 731-pc5r shape, of which this
# file is the nix-lane sibling (see with-tillandsias-builder.sh and
# with-wsl2-builder.sh). local-ci.sh deliberately omits -e (run-every-check,
# report-at-end design), and an unconditional `set -e` here silently re-arms
# errexit there. The helper body still runs under its own strict options; the
# restore hands a sourcer back exactly the option state it entered with.
#
# Capture must NOT use a $(...) subshell: command substitution clears errexit
# (shopt inherit_errexit is off), so `$(set +o)` records -e as absent even when
# the caller had it. Read $- and [[ -o pipefail ]] in the current shell, and
# restore by REMOVING only what the caller lacked — the helper only ever adds.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    _NB_CALLER_FLAGS="$-"
    _NB_CALLER_PIPEFAIL=0
    [[ -o pipefail ]] && _NB_CALLER_PIPEFAIL=1
    # Idempotent; invoked EXPLICITLY at every sourced return site below. NOT a
    # RETURN trap — see the siblings for the 2026-08-16 cross-file re-fire.
    _nb_restore_caller_opts() {
        [[ -n "${_NB_CALLER_FLAGS:-}" ]] || return 0
        [[ "$_NB_CALLER_FLAGS" == *e* ]] || set +e
        [[ "$_NB_CALLER_FLAGS" == *u* ]] || set +u
        [[ "$_NB_CALLER_PIPEFAIL" == 1 ]] || set +o pipefail
        unset _NB_CALLER_FLAGS _NB_CALLER_PIPEFAIL
        return 0
    }
fi
set -euo pipefail

_NB_SELF="${BASH_SOURCE[0]}"
_NB_CONTAINER_NAME="${TILLANDSIAS_NIX_BUILDER_CONTAINER:-tillandsias-nix-builder}"
_NB_IMAGE_NAME="${TILLANDSIAS_NIX_BUILDER_IMAGE:-tillandsias-nix-builder}"
_NB_CHROOT_STORE="${TILLANDSIAS_NIX_CHROOT_STORE:-$HOME/.local/share/tillandsias/nix-store}"
_NB_CA_DIR="${TILLANDSIAS_CA_DIR:-/tmp/tillandsias-ca}"
_NB_REPO_ROOT="$(cd "$(dirname "${_NB_SELF}")/.." && pwd)"

# Direct invocation runs the given command; sourced invocation is guarded below.
_NB_DIRECT=0
[[ "${BASH_SOURCE[0]}" == "$0" ]] && _NB_DIRECT=1

# ── Guard: skip if NIX_BUILD_LANE is not container ────────────────────────
if [[ "${NIX_BUILD_LANE:-}" != "container" ]]; then
    [[ "$_NB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    ! declare -F _nb_restore_caller_opts >/dev/null || _nb_restore_caller_opts
    return 0 2>/dev/null || exit 0
fi

# ── Guard: skip inside any OCI/container runtime ──────────────────────────
# Past the guard above the lane was EXPLICITLY requested, so a silent no-op
# here swallows the request — on Silverblue every toolbox shell has
# container=oci, and the lane vanished without a word. Name why, then pass
# through.
if [[ "${container:-}" == "oci" ]] || [[ "${container:-}" == "podman" ]]; then
    echo "[nix-builder] NIX_BUILD_LANE=container requested, but this shell is already inside a container runtime (container=${container:-}); the lane cannot nest — passing through on the current toolchain." >&2
    [[ "$_NB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    ! declare -F _nb_restore_caller_opts >/dev/null || _nb_restore_caller_opts
    return 0 2>/dev/null || exit 0
fi

# ── Guard: skip on non-Linux ──────────────────────────────────────────────
if [[ "$(uname -s)" != "Linux" ]]; then
    [[ "$_NB_DIRECT" == 1 && $# -gt 0 ]] && exec "$@"
    ! declare -F _nb_restore_caller_opts >/dev/null || _nb_restore_caller_opts
    return 0 2>/dev/null || exit 0
fi

# ── Guard: require podman ─────────────────────────────────────────────────
if ! command -v podman &>/dev/null; then
    echo "[nix-builder] FATAL: podman is required for NIX_BUILD_LANE=container" >&2
    exit 1
fi

# ── Neutralize enclave proxy for podman operations ────────────────────────
if [[ -f "$(dirname "${_NB_SELF}")/podman-neutralize-proxy.sh" ]]; then
    source "$(dirname "${_NB_SELF}")/podman-neutralize-proxy.sh"
fi

# ── Ensure the builder image exists (idempotent) ──────────────────────────
_nix_builder_image_exists() {
    podman image exists "$_NB_IMAGE_NAME" 2>/dev/null
}

_nix_builder_ensure_image() {
    if _nix_builder_image_exists; then
        return 0
    fi
    local containerfile
    containerfile="$(dirname "${_NB_SELF}")/../nix/builder/Containerfile"
    if [[ ! -f "$containerfile" ]]; then
        echo "[nix-builder] FATAL: Containerfile not found at $containerfile" >&2
        return 1
    fi
    echo "[nix-builder] Building '$_NB_IMAGE_NAME' image (first run)..."
    podman build -t "$_NB_IMAGE_NAME" -f "$containerfile" "$(dirname "$containerfile")" \
        2>&1 | while IFS= read -r line; do printf '  [build] %s\n' "$line"; done
}

# ── Container running? ────────────────────────────────────────────────────
_nix_builder_running() {
    [[ "$(podman inspect -f '{{.State.Running}}' "$_NB_CONTAINER_NAME" 2>/dev/null)" == "true" ]]
}

# ── Ensure persistent nix store exists ────────────────────────────────────
_nix_builder_ensure_store() {
    mkdir -p "$_NB_CHROOT_STORE" 2>/dev/null || return 1
    [ -d "$_NB_CHROOT_STORE/nix/store" ] || return 0  # empty is fine, will populate
}

# ── Build the podman run args ─────────────────────────────────────────────
_nix_builder_run_args() {
    # Common podman args: privileged, network host, read-write store
    local -a args=(
        --rm
        --name "$_NB_CONTAINER_NAME"
        --privileged
        --network host
        --security-opt label=disable
        -v "$_NB_CHROOT_STORE:/host-store"
        -v "$_NB_REPO_ROOT:/work"
    )

    # Mount TLS CA if present
    if [[ -d "$_NB_CA_DIR" ]]; then
        args+=(-v "$_NB_CA_DIR:/tmp/tillandsias-ca:ro")
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

    echo "[nix-builder] Execing inside '$_NB_CONTAINER_NAME' container..."

    # Wrap the command to truly UNSET proxy env vars (empty string is not
    # enough — nix's bundled libcurl interprets http_proxy="" as "use proxy
    # at empty host" whereas unset means "no proxy at all").
    local _PROXY_UNSET="unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY 2>/dev/null;"

    exec podman run "${run_args[@]}" \
        "$_NB_IMAGE_NAME" \
        -c "cd /work && $_PROXY_UNSET $CMD_QUOTED"
}

# ── Can the builder image serve this command? ─────────────────────────────
# The image has nix, bash, curl, jq — nothing else. `nix ...` is the lane's
# purpose; `bash ...` covers the documented nix-build-container.sh entry.
# Everything else (cargo, ./build.sh, ...) would exec into a container that
# cannot run it and die confusingly deep inside podman — refuse it up front.
_nix_builder_can_serve() {
    [[ "${1:-}" == "nix" || "${1:-}" == "bash" ]]
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
        echo "usage: $_NB_SELF <command> [args...]" >&2
        echo "  NIX_BUILD_LANE=container must be set." >&2
        exit 2
    fi

    if ! _nix_builder_can_serve "$@"; then
        echo "[nix-builder] FATAL: NIX_BUILD_LANE=container can only serve nix invocations" >&2
        echo "[nix-builder]   (the builder image has nix/bash/curl/jq — no cargo, no host toolchain)." >&2
        echo "[nix-builder]   Refusing to run inside the container: $*" >&2
        echo "[nix-builder]   Unset NIX_BUILD_LANE for host builds, or run e.g.:" >&2
        echo "[nix-builder]     scripts/with-nix-builder.sh nix build .#tillandsias-x86_64-musl" >&2
        exit 1
    fi

    # Route nix build commands through the pre-fetch wrapper
    if _nix_builder_is_nix_build "$@"; then
        local nix_build_script
        nix_build_script="$(dirname "${_NB_SELF}")/nix-build-container.sh"
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
    # Sourced re-exec would relaunch the CALLING script (e.g. build.sh) inside
    # the builder container. That cannot work: the caller's $0 is a
    # host-absolute path while the repo is mounted at /work, and even with the
    # path rewritten to /work the image has no cargo, so a full build.sh
    # cannot run there. Fail loudly instead of exec-ing into a container that
    # cannot serve the command (this exits the sourcing script — deliberate).
    echo "[nix-builder] FATAL: NIX_BUILD_LANE=container is set, but '$0' is not a nix invocation the builder image can serve (it has no cargo, no host toolchain)." >&2
    echo "[nix-builder]   Unset NIX_BUILD_LANE for this command, or invoke the lane directly:" >&2
    echo "[nix-builder]     scripts/with-nix-builder.sh nix build .#<output>" >&2
    exit 1
fi
