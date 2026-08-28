#!/usr/bin/env bash
# nix-push-cache.sh — push crane dep closures to the enclave nix binary cache
#
# After a successful crane build, pushes the 4 deps closures (the expensive
# artifacts) to the enclave cache so other hosts can substitute them instead of
# cold-compiling. Gates on the cache being reachable — if it is not, exits 0
# silently (a missing push is not a build failure).
#
# SCOPE — LOCAL ROUND-TRIP PLACEHOLDER. "Other hosts" above is aspiration, not
# implementation: the target is this host's own harmonia cache
# (nix-cache-service.sh), and harmonia is SERVE-ONLY — it exposes no upload
# endpoint, so `nix copy --to https://...` against it can only fail or no-op.
# Cross-host push (a writable shared cache and how hosts trust it) is 790-6n2k
# work gated on an operator decision; until that lands this script exists to
# exercise the flag/closure plumbing locally and to fail loudly rather than
# pretend a push happened.
#
# GRAMMAR (exactly one line on stdout)
#   ok:nix-push:<pushed=<n>>:total=<n>
#   ok:nix-push:skip:cache-unreachable
#   ok:nix-push:skip:no-nix
#   ok:nix-push:skip:no-store
#   blocked:nix-push:<eval-failed|push-failed|no-ca-bundle>
#
# Exit 0 on ok/skip, 1 on blocked.
#
# USAGE
#   scripts/nix-push-cache.sh             # push all 4 deps closures
#   scripts/nix-push-cache.sh --dry-run   # show what would be pushed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHROOT_STORE="${TILLANDSIAS_NIX_CHROOT_STORE:-$HOME/.local/share/tillandsias/nix-store}"
NIX_CACHE_SCRIPT="${TILLANDSIAS_NIX_CACHE_SCRIPT:-$SCRIPT_DIR/nix-cache-service.sh}"
NIX_FEATURES=(--extra-experimental-features "nix-command flakes")
CA_DIR="${TILLANDSIAS_CA_DIR:-/tmp/tillandsias-ca}"

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

# Check cache is reachable.
cache_reachable() {
    [[ -x "$NIX_CACHE_SCRIPT" ]] || return 1
    local status
    status="$("$NIX_CACHE_SCRIPT" status 2>/dev/null)" || return 1
    [[ "$status" == *"running"* ]]
}

# ── Main ──────────────────────────────────────────────────────────────────
have_nix || { echo "ok:nix-push:skip:no-nix"; exit 0; }
store_present || { echo "ok:nix-push:skip:no-store"; exit 0; }
cache_reachable || { echo "ok:nix-push:skip:cache-unreachable"; exit 0; }

# Get the cache endpoint and TLS CA for nix copy. Port and state dir mirror
# nix-cache-service.sh — honor the same env overrides instead of hardcoding.
CACHE_URL="https://127.0.0.1:${TILLANDSIAS_NIX_CACHE_HOST_PORT:-5111}"
CA_BUNDLE="${TILLANDSIAS_NIX_CACHE_STATE:-$HOME/.local/share/tillandsias/nix-cache}/ca-bundle.crt"
if [[ ! -s "$CA_BUNDLE" ]]; then
    echo "  [push] CA bundle missing or empty at $CA_BUNDLE" >&2
    echo "blocked:nix-push:no-ca-bundle"
    exit 1
fi

PUSHED=0
FAILED=0

for out in "${FLAKE_OUTPUTS[@]}"; do
    p="$(deps_out_path "$out")" || { echo "  [push] skip $out (eval failed)" >&2; FAILED=$((FAILED + 1)); continue; }

    # Check if the closure is present in the local store.
    if ! _nix path-info "$p" >/dev/null 2>&1; then
        echo "  [push] skip $out (not in local store)" >&2
        continue
    fi

    if [[ "$DRY_RUN" == 1 ]]; then
        echo "  [push] would push $out ($p)" >&2
        PUSHED=$((PUSHED + 1))
        continue
    fi

    echo "  [push] pushing $out ($p)..." >&2
    if _nix copy --to "$CACHE_URL" "$p" \
        --ssl-cert-file "$CA_BUNDLE" 2>/dev/null; then
        PUSHED=$((PUSHED + 1))
    else
        echo "  [push] FAILED $out" >&2
        FAILED=$((FAILED + 1))
    fi
done

TOTAL=$((PUSHED + FAILED))
if [[ "$FAILED" -gt 0 ]]; then
    echo "blocked:nix-push:push-failed:pushed=${PUSHED}:failed=${FAILED}:total=${TOTAL}"
    exit 1
fi

echo "ok:nix-push:pushed=${PUSHED}:total=${TOTAL}"
exit 0
