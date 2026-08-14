#!/usr/bin/env bash
# @trace order:736-mcy3, spec:ci-release
#
# nix-toolbox.sh — give this host a usable `nix` invocation, creating and
# initializing a toolbox if that is what it takes. Idempotent: safe to run on a
# host that already has everything, and safe to run twice concurrently-ish.
#
# WHY THIS EXISTS. Verifying order 736-mcy3 needs a real `nix build` from a
# pristine clone, and the obvious route was blocked in three different ways on
# this Silverblue host, none of which are unusual:
#
#   1. `nix` is installed but `nix-daemon` is INACTIVE, and starting it needs
#      privileges an unattended session does not have (`sudo` prompts).
#   2. `podman pull` fails because ~/.config/containers/containers.conf sets
#      http_proxy=http://proxy:3128 for the tillandsias enclave — and `proxy`
#      only resolves while that container runs. A stopped enclave breaks image
#      pulls for everything else on the host.
#   3. A fresh `fedora-toolbox` has neither /nix nor passwordless sudo, so
#      "just use a toolbox" is not by itself a nix.
#
# So the strategy is a PREFERENCE ORDER, and the script says which rung it
# landed on rather than pretending they are equivalent — a chroot-store build
# repopulates from substituters and is much slower than a shared daemon store.
#
#   daemon   host nix + running nix-daemon        (fastest; shares /nix)
#   chroot   host nix + rootless store under HOME (no daemon, no privileges)
#   toolbox  containerized nix                    (hosts with no nix at all)
#
# GRAMMAR (exactly one line on stdout)
#   ok:nix-toolbox:<daemon|chroot|toolbox>
#   blocked:nix-toolbox:<no-nix-and-no-toolbox|image-pull-failed|create-failed>
#
# USAGE
#   scripts/nix-toolbox.sh ensure            # print the verdict, prepare the rung
#   scripts/nix-toolbox.sh run -- <cmd...>   # run <cmd> with a working nix
#   scripts/nix-toolbox.sh nix-args          # print the flags for the chosen rung
#
# Exit 0 on ok, 1 on blocked.

set -uo pipefail

TOOLBOX_NAME="${TILLANDSIAS_NIX_TOOLBOX:-tillandsias-nix}"
TOOLBOX_IMAGE="${TILLANDSIAS_NIX_TOOLBOX_IMAGE:-registry.fedoraproject.org/fedora-toolbox:44}"
CHROOT_STORE="${TILLANDSIAS_NIX_CHROOT_STORE:-$HOME/.local/share/tillandsias/nix-store}"
NIX_FEATURES=(--extra-experimental-features "nix-command flakes")

# The enclave proxy is only reachable while the enclave runs; neutralize it for
# registry traffic rather than starting the whole stack to pull one image.
_podman() { env http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= podman "$@"; }
_toolbox() { env http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= toolbox "$@"; }

daemon_live() {
    command -v nix >/dev/null 2>&1 || return 1
    # Must exercise the STORE, not just evaluation. `nix eval --expr '1'` is
    # pure and answers fine with the daemon dead — this probe said `daemon` on a
    # host where `nix build` then failed with "cannot connect to socket", which
    # is the exact false-green this script exists to avoid.
    nix "${NIX_FEATURES[@]}" store ping >/dev/null 2>&1
}

chroot_works() {
    command -v nix >/dev/null 2>&1 || return 1
    mkdir -p "$CHROOT_STORE" 2>/dev/null || return 1
    nix "${NIX_FEATURES[@]}" --store "$CHROOT_STORE" store ping >/dev/null 2>&1
}

toolbox_exists() {
    command -v toolbox >/dev/null 2>&1 || return 1
    _toolbox list -c 2>/dev/null | awk '{print $2}' | grep -qx "$TOOLBOX_NAME"
}

ensure_toolbox() {
    command -v toolbox >/dev/null 2>&1 || return 1
    if toolbox_exists; then
        return 0
    fi
    # Pull explicitly so a proxy failure is reported as itself rather than as a
    # create failure.
    if ! _podman image exists "$TOOLBOX_IMAGE" 2>/dev/null; then
        _podman pull "$TOOLBOX_IMAGE" >/dev/null 2>&1 || return 2
    fi
    _toolbox create -y "$TOOLBOX_NAME" >/dev/null 2>&1 || return 3
    return 0
}

resolve_rung() {
    if daemon_live; then
        printf 'daemon\n'
        return 0
    fi
    if chroot_works; then
        printf 'chroot\n'
        return 0
    fi
    ensure_toolbox
    case "$?" in
        0) if _toolbox run -c "$TOOLBOX_NAME" command -v nix >/dev/null 2>&1; then
               printf 'toolbox\n'; return 0
           fi
           printf 'blocked:no-nix-and-no-toolbox\n'; return 1 ;;
        2) printf 'blocked:image-pull-failed\n'; return 1 ;;
        *) printf 'blocked:create-failed\n'; return 1 ;;
    esac
}

cmd="${1:-ensure}"
shift || true

case "$cmd" in
    ensure)
        rung="$(resolve_rung)"
        case "$rung" in
            blocked:*) echo "blocked:nix-toolbox:${rung#blocked:}"; exit 1 ;;
            *) echo "ok:nix-toolbox:$rung"; exit 0 ;;
        esac
        ;;
    nix-args)
        rung="$(resolve_rung)"
        case "$rung" in
            daemon)  printf '%s\n' "${NIX_FEATURES[@]}" ;;
            chroot)  printf '%s\n' "${NIX_FEATURES[@]}" --store "$CHROOT_STORE" ;;
            *)       echo "blocked:nix-toolbox:${rung#blocked:}" >&2; exit 1 ;;
        esac
        ;;
    run)
        [ "${1:-}" = "--" ] && shift
        [ "$#" -gt 0 ] || { echo "usage: $0 run -- <command...>" >&2; exit 2; }
        rung="$(resolve_rung)"
        case "$rung" in
            daemon|chroot) exec "$@" ;;
            toolbox)       exec _toolbox run -c "$TOOLBOX_NAME" "$@" ;;
            *)             echo "blocked:nix-toolbox:${rung#blocked:}" >&2; exit 1 ;;
        esac
        ;;
    *)
        echo "usage: $0 [ensure|nix-args|run -- <command...>]" >&2
        exit 2
        ;;
esac
