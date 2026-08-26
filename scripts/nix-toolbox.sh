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
# THE STORE IS THE CACHE (order 795-h8er)
#
# `CHROOT_STORE` is anchored in $HOME, not in the worktree, so it is ALREADY
# shared by every worktree on the host and already survives toolbox recreation
# — the toolbox is disposable, the store is not. Measured on macuahuitl
# 2026-08-17: 5.8 GiB, 4,478 paths, rust toolchains + the whole vendored cargo
# set. So persistence was never the missing piece. Two real defects were:
#
#   1. NOTHING WAS ROOTED. All four GC roots were `auto` indirect roots
#      pointing into a fork worktree that had since been deleted, so every
#      byte of that 5.8 GiB was garbage by nix's reckoning. The daily
#      `build_cache_hygiene` lane prescribes `nix store gc` — which would have
#      deleted the entire cache it was meant to be pruning. A cache with no
#      roots is not a cache; it is garbage that has not been collected yet.
#
#   2. NOTHING WAS RECLAIMED. The expensive artifact is crane's deps closure,
#      and it moves whenever Cargo.lock or flake.lock moves — three times in
#      the two days before this was written. Each move orphans the previous
#      multi-GiB closure forever. Measured at the same moment: FIVE stale deps
#      closures resident, ZERO current ones.
#
# Hence `pin` and `gc`, and the shape of the policy: PIN WHAT IS CURRENT,
# COLLECT THE REST, AND ONLY ABOVE A CEILING. Pinning is what makes collecting
# safe, so `gc` refuses to collect when it could not work out what to pin —
# see the eval-failure guard in `store_gc`. Roots live inside the store itself,
# never in a worktree, which is what defect 1 was.
#
# GRAMMAR (exactly one line on stdout)
#   ok:nix-toolbox:<daemon|chroot|toolbox>
#   blocked:nix-toolbox:<no-nix-and-no-toolbox|image-pull-failed|create-failed>
#   ok:nix-store:<absent|empty|populated>:paths=<n>:size=<n>G:pinned=<n>
#   ok:nix-store:<cold|warm>:deps=<present>/<resolved>:paths=<n>:size=<n>G:pinned=<n>
#   ok:nix-store-pin:<pinned>/<resolved> of <total>
#   ok:nix-store-gc:<under-ceiling|would-free=<n>G|freed=<n>G>:size=<n>G:ceiling=<n>G
#   skip:nix-store:<no-store>
#   blocked:nix-store-gc:<unresolved-deps|nix-unusable|collection-failed>
#
# The `ensure` line is UNCHANGED and stays byte-identical — callers and
# scripts/test-nix-toolbox.sh match it anchored. Cold/warm is reported by
# `store-status --deps` rather than bolted onto `ensure`, because deciding it
# honestly costs a flake evaluation and `ensure` must stay cheap.
#
# USAGE
#   scripts/nix-toolbox.sh ensure            # print the verdict, prepare the rung
#   scripts/nix-toolbox.sh run -- <cmd...>   # run <cmd> with a working nix
#   scripts/nix-toolbox.sh nix-args          # print the flags for the chosen rung
#   scripts/nix-toolbox.sh store-path        # print the persistent store root
#   scripts/nix-toolbox.sh store-status      # cheap facts; --deps adds cold/warm
#   scripts/nix-toolbox.sh pin               # root the CURRENT deps closures
#   scripts/nix-toolbox.sh gc                # pin, then collect above the ceiling
#
# Exit 0 on ok/skip, 1 on blocked.

set -uo pipefail


# ORDER 799-tb7q — resolve `jq` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has it.
# shellcheck source=scripts/lib/tool-dispatch.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/tool-dispatch.sh" 2>/dev/null || true
if command -v resolve_tool >/dev/null 2>&1; then
    JQ="$(resolve_tool jq || printf 'jq')"
else
    JQ="jq"   # lib unavailable: preserve the previous behaviour exactly
fi

TOOLBOX_NAME="${TILLANDSIAS_NIX_TOOLBOX:-tillandsias-nix}"
TOOLBOX_IMAGE="${TILLANDSIAS_NIX_TOOLBOX_IMAGE:-registry.fedoraproject.org/fedora-toolbox:44}"
CHROOT_STORE="${TILLANDSIAS_NIX_CHROOT_STORE:-$HOME/.local/share/tillandsias/nix-store}"
NIX_FEATURES=(--extra-experimental-features "nix-command flakes")

# Size ceiling for the persistent store, in GiB. Chosen against the sibling
# figure in methodology `build_cache_hygiene`, which reclaims target/ at 40
# GiB: one generation of deps closures across the four musl outputs is a few
# GiB, so 20 leaves room for the current set plus a couple of in-flight
# generations while still bounding the "ephemeral-ish because it caches"
# growth the operator asked about.
STORE_CEILING_GIB="${TILLANDSIAS_NIX_STORE_CEILING_GIB:-20}"

# Roots go INSIDE the store, which is the fix for defect 1 above: a root under
# a worktree dies with the worktree and takes the cache with it.
PIN_SUBDIR="nix/var/nix/gcroots/tillandsias"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The same four outputs scripts/check-nix-deps-stability.sh perturbs. Keep the
# two lists in step: that script proves the deps closures are content-stable,
# this one keeps them alive long enough for the stability to pay off.
FLAKE_OUTPUTS=(
    tillandsias-x86_64-musl
    tillandsias-headless-x86_64-musl
    tillandsias-headless-aarch64-musl
    tillandsias-router-sidecar-x86_64-musl
)

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

# ---------------------------------------------------------------------------
# Persistent store (order 795-h8er)
# ---------------------------------------------------------------------------

# Always addressed explicitly with --store. The host's own /nix is NOT ours to
# collect, so nothing below can be pointed at it even on the daemon rung.
_store_nix() { nix "${NIX_FEATURES[@]}" --store "$CHROOT_STORE" "$@"; }

# nix reports store paths as LOGICAL /nix/store/... paths even for a chroot
# store, and this JSON schema gives some of them as bare basenames. Both must
# end up logical: a GC root pointing at the PHYSICAL path is not recognized.
# (Same family as the 790-mbk9 --out-link trap.)
_logical() {
    case "$1" in
        /nix/store/*) printf '%s' "$1" ;;
        *)            printf '/nix/store/%s' "$1" ;;
    esac
}

store_present() { [ -d "$CHROOT_STORE/nix/store" ]; }

store_size_gib() { # rounded down; du -sk for BSD/macOS portability
    local kib
    kib="$(du -sk "$CHROOT_STORE" 2>/dev/null | awk '{print $1}')"
    [ -n "$kib" ] || { printf '0'; return; }
    printf '%s' $((kib / 1048576))
}

# `wc -l` pads its output with leading blanks on BSD/macOS, which would emit
# `paths= 4506` and break the grammar for the osx sibling — strip it.
_count_lines() { tr -d '[:space:]'; }

store_path_count() {
    local n
    n="$(ls "$CHROOT_STORE/nix/store" 2>/dev/null | wc -l | _count_lines)"
    printf '%s' "${n:-0}"
}

pinned_count() {
    local n
    n="$(ls "$CHROOT_STORE/$PIN_SUBDIR" 2>/dev/null | wc -l | _count_lines)"
    printf '%s' "${n:-0}"
}

# Resolve the crane deps OUTPUT path for one flake output. EVALUATION ONLY —
# this must never trigger a build, or the hygiene lane would compile ~1,000
# crates as a side effect of tidying up.
# Prints the logical path on success; returns 1 if evaluation failed.
deps_out_path() { # <flake-output>
    local out="$1" json depsdrv djson outpath
    json="$(cd "$REPO_ROOT" && _store_nix derivation show ".#${out}" 2>/dev/null)" || return 1
    [ -n "$json" ] || return 1
    depsdrv="$(printf '%s' "$json" | "$JQ" -r '
        (if has("derivations") then .derivations else . end)
        | to_entries[0].value
        | ((.inputs.drvs // {}) + (.inputDrvs // {}))
        | keys[] | select(test("-deps-"))' 2>/dev/null | head -n 1)"
    [ -n "$depsdrv" ] || return 1
    djson="$(cd "$REPO_ROOT" && _store_nix derivation show "$(_logical "$depsdrv")" 2>/dev/null)" || return 1
    outpath="$(printf '%s' "$djson" | "$JQ" -r '
        (if has("derivations") then .derivations else . end)
        | to_entries[0].value | .outputs.out.path' 2>/dev/null)"
    [ -n "$outpath" ] && [ "$outpath" != "null" ] || return 1
    _logical "$outpath"
}

# Root every CURRENT deps closure that is already realized. Absent closures are
# skipped, not built. Sets PIN_RESOLVED / PIN_PINNED for callers.
store_pin() {
    PIN_RESOLVED=0
    PIN_PINNED=0
    store_present || return 0
    mkdir -p "$CHROOT_STORE/$PIN_SUBDIR" 2>/dev/null || return 1
    local out p
    for out in "${FLAKE_OUTPUTS[@]}"; do
        p="$(deps_out_path "$out")" || continue
        PIN_RESOLVED=$((PIN_RESOLVED + 1))
        _store_nix path-info "$p" >/dev/null 2>&1 || continue
        # ln -sfn, so re-pinning REPLACES the root for that output rather than
        # accumulating one per generation — "never duplicated".
        ln -sfn "$p" "$CHROOT_STORE/$PIN_SUBDIR/deps-$out" 2>/dev/null || continue
        PIN_PINNED=$((PIN_PINNED + 1))
    done
    return 0
}

store_gc() {
    local dry="${1:-}"
    store_present || { echo "skip:nix-store:no-store"; return 0; }
    _store_nix store ping >/dev/null 2>&1 || { echo "blocked:nix-store-gc:nix-unusable"; return 1; }

    store_pin
    # THE SAFETY INTERLOCK. If evaluation could not tell us what is current, we
    # do not know what to protect, and collecting would delete the live deps
    # closure along with the stale ones. Refuse rather than guess. A resolved
    # closure that is merely ABSENT is fine — there is nothing to lose.
    if [ "$PIN_RESOLVED" -lt "${#FLAKE_OUTPUTS[@]}" ]; then
        echo "blocked:nix-store-gc:unresolved-deps"
        echo "  resolved ${PIN_RESOLVED}/${#FLAKE_OUTPUTS[@]} deps closures by evaluation;" >&2
        echo "  refusing to collect because the unresolved ones cannot be pinned" >&2
        echo "  and would be deleted as garbage. Fix the flake evaluation first." >&2
        return 1
    fi

    local size ceiling excess_gib
    size="$(store_size_gib)"
    ceiling="$STORE_CEILING_GIB"
    if [ "$size" -le "$ceiling" ]; then
        echo "ok:nix-store-gc:under-ceiling:size=${size}G:ceiling=${ceiling}G"
        return 0
    fi

    excess_gib=$((size - ceiling))
    if [ "$dry" = "--dry-run" ]; then
        # --max cannot be combined with --dry-run, so a dry run reports the
        # decision and the budget rather than pretending to model the outcome.
        echo "ok:nix-store-gc:would-free=${excess_gib}G:size=${size}G:ceiling=${ceiling}G"
        return 0
    fi

    # Do NOT swallow the collection's exit code. A failed gc that still
    # reported `ok:...freed=0G` would read as "the cache is within policy"
    # every single day while it grew past the ceiling unchecked.
    if ! _store_nix store gc --max "${excess_gib}G" >/dev/null 2>&1; then
        echo "blocked:nix-store-gc:collection-failed"
        echo "  nix store gc --max ${excess_gib}G failed against $CHROOT_STORE;" >&2
        echo "  the store is ${size}G against a ${ceiling}G ceiling and was NOT pruned." >&2
        return 1
    fi
    local after
    after="$(store_size_gib)"
    echo "ok:nix-store-gc:freed=$((size - after))G:size=${after}G:ceiling=${ceiling}G"
    return 0
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
    store-path)
        printf '%s\n' "$CHROOT_STORE"
        ;;
    store-status)
        if ! store_present; then
            echo "skip:nix-store:no-store"
            exit 0
        fi
        paths="$(store_path_count)"
        size="$(store_size_gib)"
        pinned="$(pinned_count)"
        if [ "${1:-}" = "--deps" ]; then
            # Honest cold/warm: WARM means the next build will actually hit,
            # not merely that the directory has bytes in it. Costs a flake
            # evaluation per output, which is why it is opt-in.
            resolved=0; present=0
            for out in "${FLAKE_OUTPUTS[@]}"; do
                p="$(deps_out_path "$out")" || continue
                resolved=$((resolved + 1))
                _store_nix path-info "$p" >/dev/null 2>&1 && present=$((present + 1))
            done
            state=cold
            [ "$present" -gt 0 ] && state=warm
            echo "ok:nix-store:${state}:deps=${present}/${resolved}:paths=${paths}:size=${size}G:pinned=${pinned}"
            exit 0
        fi
        state=populated
        [ "$paths" -eq 0 ] && state=empty
        echo "ok:nix-store:${state}:paths=${paths}:size=${size}G:pinned=${pinned}"
        ;;
    pin)
        if ! store_present; then
            echo "skip:nix-store:no-store"
            exit 0
        fi
        store_pin
        echo "ok:nix-store-pin:${PIN_PINNED}/${PIN_RESOLVED} of ${#FLAKE_OUTPUTS[@]}"
        ;;
    gc)
        store_gc "${1:-}"
        exit $?
        ;;
    *)
        echo "usage: $0 [ensure|nix-args|run -- <command...>|store-path|store-status [--deps]|pin|gc [--dry-run]]" >&2
        exit 2
        ;;
esac
