#!/usr/bin/env bash
# nix-push-cache.sh — populate the per-host cache store with crane dep closures
#
# RE-CUT 2026-08-28 (790-6n2k reconciliation). The previous shape ran
# `nix copy --to https://127.0.0.1:5111` — an UPLOAD against harmonia, which
# is serve-only and exposes no upload endpoint, so the push could only fail.
# Publication on this host is LOCAL: harmonia serves the chroot store
# directly, so a closure is published the moment it is valid there.
#
# The build lane already populates the store itself (with-nix-builder.sh runs
# in-container `nix copy --to /host-store --no-check-sigs <closure>` after a
# successful build, then `nix-toolbox.sh pin`). This script is the HOST-SIDE
# re-drive of that same mechanism: it copies the deps closures from the host's
# default store into the chroot store when they are missing there, and pins.
# --no-check-sigs matches the lane: harmonia signs at SERVE time
# (sign_key_paths in nix-cache-service.sh), store paths carry no signatures.
# Cross-host publication (a shared writable cache) is deliberately absent —
# the cache is PER-HOST until a shared cache is designed (operator 2026-08-28).
#
# GRAMMAR (exactly one line on stdout)
#   ok:nix-push:local:served=<n>:copied=<n>:total=<n>
#   ok:nix-push:skip:no-nix
#   ok:nix-push:skip:no-store
#   blocked:nix-push:copy-failed:served=<n>:copied=<n>:failed=<n>:total=<n>
#
# served  = deps closures already valid in the chroot store harmonia serves
# copied  = closures this run copied in from the host default store
# total   = flake outputs whose deps closure exists somewhere locally
#
# Exit 0 on ok/skip, 1 on blocked.
#
# USAGE
#   scripts/nix-push-cache.sh             # populate + pin all 4 deps closures
#   scripts/nix-push-cache.sh --dry-run   # show what would be copied

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHROOT_STORE="${TILLANDSIAS_NIX_CHROOT_STORE:-$HOME/.local/share/tillandsias/nix-store}"
NIX_FEATURES=(--extra-experimental-features "nix-command flakes")

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# The same four outputs nix-toolbox.sh pins. Keep the lists in step.
FLAKE_OUTPUTS=(
    tillandsias-x86_64-musl
    tillandsias-headless-x86_64-musl
    tillandsias-headless-aarch64-musl
    tillandsias-router-sidecar-x86_64-musl
)

have_nix() { command -v nix >/dev/null 2>&1; }
store_present() { [ -d "$CHROOT_STORE/nix/store" ]; }

_nix() { nix "${NIX_FEATURES[@]}" --store "$CHROOT_STORE" "$@"; }
_host_nix() { nix "${NIX_FEATURES[@]}" "$@"; }

_logical() {
    case "$1" in
        /nix/store/*) printf '%s' "$1" ;;
        *)            printf '/nix/store/%s' "$1" ;;
    esac
}

# Resolve the deps OUTPUT path for one flake output (same as nix-toolbox.sh).
deps_out_path() {
    local out="$1" json depsdrv djson outpath
    json="$(cd "$REPO_ROOT" && _nix derivation show ".#${out}" 2>/dev/null)" || return 1
    [ -n "$json" ] || return 1
    depsdrv="$(printf '%s' "$json" | jq -r '
        (if has("derivations") then .derivations else . end)
        | to_entries[0].value
        | ((.inputs.drvs // {}) + (.inputDrvs // {}))
        | keys[] | select(test("-deps-"))' 2>/dev/null | head -n 1)"
    [ -n "$depsdrv" ] || return 1
    djson="$(cd "$REPO_ROOT" && _nix derivation show "$(_logical "$depsdrv")" 2>/dev/null)" || return 1
    outpath="$(printf '%s' "$djson" | jq -r '
        (if has("derivations") then .derivations else . end)
        | to_entries[0].value | .outputs.out.path' 2>/dev/null)"
    [ -n "$outpath" ] && [ "$outpath" != "null" ] || return 1
    _logical "$outpath"
}

# ── Main ──────────────────────────────────────────────────────────────────
have_nix || { echo "ok:nix-push:skip:no-nix"; exit 0; }
store_present || { echo "ok:nix-push:skip:no-store"; exit 0; }

SERVED=0
COPIED=0
FAILED=0

for out in "${FLAKE_OUTPUTS[@]}"; do
    p="$(deps_out_path "$out")" || { echo "  [push] skip $out (eval failed)" >&2; continue; }

    if _nix path-info "$p" >/dev/null 2>&1; then
        echo "  [push] $out already in the served store ($p)" >&2
        SERVED=$((SERVED + 1))
        continue
    fi

    if ! _host_nix path-info "$p" >/dev/null 2>&1; then
        echo "  [push] skip $out (in neither the served nor the host store)" >&2
        continue
    fi

    if [[ "$DRY_RUN" == 1 ]]; then
        echo "  [push] would copy $out ($p) host-store -> $CHROOT_STORE" >&2
        COPIED=$((COPIED + 1))
        continue
    fi

    echo "  [push] copying $out ($p) into the served store..." >&2
    if _host_nix copy --to "$CHROOT_STORE" --no-check-sigs "$p" 2>/dev/null; then
        COPIED=$((COPIED + 1))
    else
        echo "  [push] FAILED $out" >&2
        FAILED=$((FAILED + 1))
    fi
done

TOTAL=$((SERVED + COPIED + FAILED))
if [[ "$FAILED" -gt 0 ]]; then
    echo "blocked:nix-push:copy-failed:served=${SERVED}:copied=${COPIED}:failed=${FAILED}:total=${TOTAL}"
    exit 1
fi

# Root whatever is now in the served store so GC keeps it — the same follow-up
# the build lane runs. Advisory: a pin failure leaves closures served but
# unrooted, which the next successful pin repairs.
if [[ "$DRY_RUN" == 0 && $((SERVED + COPIED)) -gt 0 ]]; then
    "$SCRIPT_DIR/nix-toolbox.sh" pin >&2 \
        || echo "  [push] warning: nix-toolbox.sh pin failed; closures unrooted until the next pin" >&2
fi

echo "ok:nix-push:local:served=${SERVED}:copied=${COPIED}:total=${TOTAL}"
exit 0
