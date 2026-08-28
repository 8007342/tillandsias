#!/usr/bin/env bash
# with-nix-builder.sh — transparent nix-in-container re-exec for crane builds
#
# When TILLANDSIAS_BUILD_LANE=container is set, routes nix builds through the
# tillandsias-builder container (images/builder/Containerfile, distro nix),
# with /nix on a named volume so a relaunch lands warm and the per-host cache
# chroot store mounted read-write at /host-store. Non-Linux hosts and
# TILLANDSIAS_BUILD_LANE != container pass through with zero overhead.
#
# THE LANE SERVES NIX INVOCATIONS ONLY. The builder image carries nix, bash,
# git, curl, and jq — no cargo, no host toolchain — so it cannot run build.sh
# or arbitrary build commands; those fail loudly below instead of exec-ing
# into a container that cannot run them.
#
# Per-host substituter wiring (790-6n2k): nix-cache-service.sh
# substituter-args is the single authority. Empty output means the cache is
# not answering and the lane degrades to cold — NO flags are added, because a
# dead substituter in the flag list makes nix retry it on every path. When it
# answers, the emitted --ssl-cert-file value is a HOST path the container
# cannot see: the bundle is mounted read-only at /run/tillandsias/ca-bundle.crt
# (the exact path images/builder/nix.conf pins) and the flag value rewritten
# to that mount.
#
# After a successful `nix build`, the lane populates the per-host cache:
# in-container `nix copy --to /host-store --no-check-sigs <closure>` (harmonia
# signs at SERVE time via sign_key_paths — nix-cache-service.sh — so store
# paths carry no signatures), then host-side `scripts/nix-toolbox.sh pin`.
#
# Usage (direct):
#   TILLANDSIAS_BUILD_LANE=container scripts/with-nix-builder.sh nix build .#tillandsias-x86_64-musl
#
# Usage (sourced — e.g. from build.sh): with TILLANDSIAS_BUILD_LANE unset this
# is a zero-overhead pass-through. With TILLANDSIAS_BUILD_LANE=container set,
# a sourced caller is a whole script — never a nix invocation the image can
# serve — so the sourced path fails loudly rather than exec-ing a doomed
# container.
#
# The container mounts:
#   - tillandsias-builder-nix (named volume) → /nix (warm build store)
#   - ~/.local/share/tillandsias/nix-store → /host-store (per-host cache store)
#   - $REPO_ROOT → /work (source tree)
#   - /tmp/tillandsias-ca → /tmp/tillandsias-ca:ro (stack TLS CA, when present)
#   - a CA bundle → /run/tillandsias/ca-bundle.crt:ro (always: cache bundle
#     when the cache answers, host system bundle otherwise — nix.conf's
#     ssl-cert-file setting must resolve for upstream TLS)

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
_NB_NIX_VOLUME="${TILLANDSIAS_NIX_BUILDER_VOLUME:-tillandsias-builder-nix}"
_NB_CHROOT_STORE="${TILLANDSIAS_NIX_CHROOT_STORE:-$HOME/.local/share/tillandsias/nix-store}"
_NB_CA_DIR="${TILLANDSIAS_CA_DIR:-/tmp/tillandsias-ca}"
_NB_CACHE_SCRIPT="${TILLANDSIAS_NIX_CACHE_SCRIPT:-$(cd "$(dirname "${_NB_SELF}")" && pwd)/nix-cache-service.sh}"
# The in-container CA path. Must stay in step with images/builder/nix.conf's
# ssl-cert-file setting — the conf pins it so cold builds verify upstream TLS.
_NB_CA_MOUNT="/run/tillandsias/ca-bundle.crt"
_NB_REPO_ROOT="$(cd "$(dirname "${_NB_SELF}")/.." && pwd)"

# Direct invocation runs the given command; sourced invocation is guarded below.
_NB_DIRECT=0
[[ "${BASH_SOURCE[0]}" == "$0" ]] && _NB_DIRECT=1

# ── Guard: skip if TILLANDSIAS_BUILD_LANE is not container ────────────────
if [[ "${TILLANDSIAS_BUILD_LANE:-}" != "container" ]]; then
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
    echo "[nix-builder] TILLANDSIAS_BUILD_LANE=container requested, but this shell is already inside a container runtime (container=${container:-}); the lane cannot nest — passing through on the current toolchain." >&2
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
    echo "[nix-builder] FATAL: podman is required for TILLANDSIAS_BUILD_LANE=container" >&2
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
    containerfile="$_NB_REPO_ROOT/images/builder/Containerfile"
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

# ── Per-host substituter wiring (790-6n2k) ────────────────────────────────
# Sets _NB_SUB_FLAGS (nix flags, cert path rewritten to the in-container
# mount) and _NB_CA_HOST (the host file to mount at _NB_CA_MOUNT). Empty
# substituter-args output = cache down = degrade-to-cold: NO substituter
# flags, but the host system bundle is still mounted so nix.conf's
# ssl-cert-file setting resolves for upstream TLS.
_NB_SUB_FLAGS=()
_NB_CA_HOST=""

_nix_builder_host_system_bundle() {
    local c
    for c in /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
             /etc/ssl/certs/ca-certificates.crt \
             /etc/ssl/cert.pem; do
        if [[ -r "$c" ]]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

_nix_builder_cache_wiring() {
    local sub_args=""
    if [[ -x "$_NB_CACHE_SCRIPT" ]]; then
        sub_args="$("$_NB_CACHE_SCRIPT" substituter-args 2>/dev/null || true)"
    fi

    local ca_host=""
    if [[ -n "$sub_args" ]]; then
        # substituter-args emits one token per line; the --ssl-cert-file value
        # is the cache state dir's ca-bundle.crt, a HOST path. Rewrite it to
        # the fixed in-container mount (the check-nix-builder-e2e.sh shape).
        ca_host="$(printf '%s\n' "$sub_args" \
            | awk 'prev == "--ssl-cert-file" { print; exit } { prev = $0 }')"
        if [[ -n "$ca_host" && -s "$ca_host" ]]; then
            sub_args="$(printf '%s\n' "$sub_args" \
                | awk -v m="$_NB_CA_MOUNT" '{ if (prev == "--ssl-cert-file") $0 = m; prev = $0; print }')"
            local _nb_flag
            while IFS= read -r _nb_flag; do
                [[ -n "$_nb_flag" ]] && _NB_SUB_FLAGS+=("$_nb_flag")
            done <<< "$sub_args"
            _NB_CA_HOST="$ca_host"
            echo "[nix-builder] per-host cache answering; substituter flags injected" >&2
            return 0
        fi
        echo "[nix-builder] cache CA bundle missing on host (${ca_host:-none}); building cold" >&2
    fi

    _NB_CA_HOST="$(_nix_builder_host_system_bundle || true)"
    return 0
}

# ── Build the podman run args ─────────────────────────────────────────────
_nix_builder_run_args() {
    # Common podman args: privileged, network host (127.0.0.1:5111 — the
    # cache's host port — must be reachable), read-write stores.
    local -a args=(
        --rm
        --name "$_NB_CONTAINER_NAME"
        --privileged
        --network host
        --security-opt label=disable
        -v "$_NB_NIX_VOLUME:/nix"
        -v "$_NB_CHROOT_STORE:/host-store"
        -v "$_NB_REPO_ROOT:/work"
    )

    # Mount TLS CA if present
    if [[ -d "$_NB_CA_DIR" ]]; then
        args+=(-v "$_NB_CA_DIR:/tmp/tillandsias-ca:ro")
    fi

    # CA bundle at the path images/builder/nix.conf pins (see wiring above).
    if [[ -n "$_NB_CA_HOST" ]]; then
        args+=(-v "$_NB_CA_HOST:$_NB_CA_MOUNT:ro")
    fi

    # Forward TILLANDSIAS_* env vars. TILLANDSIAS_BUILD_LANE=container rides
    # this loop — no separate lane flag needed since the rename.
    while IFS= read -r _nb_var; do
        args+=(-e "$_nb_var=${!_nb_var}")
    done < <(compgen -v | grep '^TILLANDSIAS_' || true)

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

# ── Populate the per-host cache after a successful build ──────────────────
# Runs INSIDE the container, appended to the build command with && so a failed
# build never populates. Resolves ./result* symlinks (nix build's cwd is
# /work), copies the closure into /host-store — the chroot store harmonia
# serves — and reports how many closure paths were new there. --no-check-sigs
# because harmonia signs at SERVE time (sign_key_paths); store paths carry no
# signatures by design. A copy failure is loud (blocked:) — a mounted rw store
# that rejects a local copy is breakage, not a degraded cache.
# In-container /etc/nix/nix.conf already enables nix-command/flakes, so the
# snippet needs no experimental-features flag.
_NB_POPULATE_SNIPPET='outs=$(for l in result result-*; do if [ -L "$l" ]; then readlink -f "$l"; fi; done | grep "^/nix/store/" | sort -u); if [ -z "$outs" ]; then echo "ok:nix-populate:copied=0"; else total=$(nix path-info -r $outs 2>/dev/null | sort -u | wc -l); pre=$(nix --store /host-store path-info -r $outs 2>/dev/null | sort -u | wc -l); if nix copy --to /host-store --no-check-sigs $outs; then echo "ok:nix-populate:copied=$((total - pre))"; else echo "blocked:nix-populate:copy-failed"; exit 1; fi; fi'

# Whether the current invocation is a build whose outputs should populate the
# per-host cache. Set in _nb_entry before _nix_builder_exec.
_NB_POPULATE=0

# ── Main: run the command inside the builder container ────────────────────
# NOT exec: the lane runs host-side follow-up (nix-toolbox.sh pin) after a
# populating build, so the wrapper must survive the container.
_nix_builder_exec() {
    _nix_builder_ensure_store || { echo "[nix-builder] FATAL: cannot create nix store" >&2; exit 1; }
    _nix_builder_ensure_image || { echo "[nix-builder] FATAL: cannot build image" >&2; exit 1; }

    # Escape the command for bash -c
    local CMD_QUOTED=""
    local arg
    for arg in "$@"; do
        CMD_QUOTED="$CMD_QUOTED$(printf '%q ' "$arg")"
    done

    local -a run_args=()
    local _nb_line
    while IFS= read -r _nb_line; do
        run_args+=("$_nb_line")
    done < <(_nix_builder_run_args)

    echo "[nix-builder] Running inside '$_NB_CONTAINER_NAME' container..." >&2

    # Wrap the command to truly UNSET proxy env vars (empty string is not
    # enough — nix's bundled libcurl interprets http_proxy="" as "use proxy
    # at empty host" whereas unset means "no proxy at all").
    local _PROXY_UNSET="unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY 2>/dev/null;"

    local _script="cd /work && $_PROXY_UNSET $CMD_QUOTED"
    if [[ "$_NB_POPULATE" == 1 ]]; then
        _script+=" && $_NB_POPULATE_SNIPPET"
    fi

    local rc=0
    podman run "${run_args[@]}" "$_NB_IMAGE_NAME" -c "$_script" || rc=$?

    if [[ "$rc" -eq 0 && "$_NB_POPULATE" == 1 ]]; then
        # Root the freshly populated closures so host-side GC keeps them. Host
        # nix is required only for the pin, never for the build; its absence
        # downgrades to a named next action, not a failure.
        if command -v nix >/dev/null 2>&1; then
            "$(dirname "${_NB_SELF}")/nix-toolbox.sh" pin \
                || echo "[nix-builder] warning: store populated but nix-toolbox.sh pin failed — closures are unrooted until the next successful pin" >&2
        else
            echo "[nix-builder] host nix absent; populated store not pinned (run scripts/nix-toolbox.sh pin from a nix-capable shell)" >&2
        fi
    fi

    exit "$rc"
}

# ── Can the builder image serve this command? ─────────────────────────────
# The image has nix, bash, git, curl, jq — nothing else. `nix ...` is the
# lane's purpose; `bash ...` covers the documented nix-build-container.sh
# entry. Everything else (cargo, ./build.sh, ...) would run in a container
# that cannot serve it and die confusingly deep inside podman — refuse it up
# front.
_nix_builder_can_serve() {
    [[ "${1:-}" == "nix" || "${1:-}" == "bash" ]]
}

# ── Detect nix build commands ─────────────────────────────────────────────
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
        echo "  TILLANDSIAS_BUILD_LANE=container must be set." >&2
        exit 2
    fi

    if ! _nix_builder_can_serve "$@"; then
        echo "[nix-builder] FATAL: TILLANDSIAS_BUILD_LANE=container can only serve nix invocations" >&2
        echo "[nix-builder]   (the builder image has nix/bash/git/curl/jq — no cargo, no host toolchain)." >&2
        echo "[nix-builder]   Refusing to run inside the container: $*" >&2
        echo "[nix-builder]   Unset TILLANDSIAS_BUILD_LANE for host builds, or run e.g.:" >&2
        echo "[nix-builder]     scripts/with-nix-builder.sh nix build .#tillandsias-x86_64-musl" >&2
        exit 1
    fi

    _nix_builder_cache_wiring

    if _nix_builder_is_nix_build "$@"; then
        _NB_POPULATE=1
        # BigPickle's prefetch is the explicit FALLBACK, not the default
        # (operator 2026-08-28): direct in-container nix build with the
        # substituter flags is the lane; the curl prefetch route exists for
        # hosts where nix's bundled libcurl cannot verify github.com.
        if [[ "${TILLANDSIAS_NIX_PREFETCH:-}" == "1" ]]; then
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
                # nix-build-container.sh forwards its args (incl. these
                # substituter flags) straight into its nix build. The path
                # must be the IN-CONTAINER one: the repo mounts at /work, and
                # the pre-reconciliation route passed the host-absolute path,
                # which does not exist inside the container.
                _nix_builder_exec bash /work/scripts/nix-build-container.sh "${build_args[@]}" "${_NB_SUB_FLAGS[@]}"
            fi
            echo "[nix-builder] TILLANDSIAS_NIX_PREFETCH=1 set but $(dirname "${_NB_SELF}")/nix-build-container.sh is not executable; falling back to direct nix build" >&2
        fi
    fi

    if [[ "${1:-}" == "nix" ]]; then
        _nix_builder_exec "$@" "${_NB_SUB_FLAGS[@]}"
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
    echo "[nix-builder] FATAL: TILLANDSIAS_BUILD_LANE=container is set, but '$0' is not a nix invocation the builder image can serve (it has no cargo, no host toolchain)." >&2
    echo "[nix-builder]   Unset TILLANDSIAS_BUILD_LANE for this command, or invoke the lane directly:" >&2
    echo "[nix-builder]     scripts/with-nix-builder.sh nix build .#<output>" >&2
    exit 1
fi
