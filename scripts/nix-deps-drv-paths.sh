#!/usr/bin/env bash
# @trace order:765-8hc3, spec:ci-release
#
# nix-deps-drv-paths.sh — print the crane DEPS derivation path backing each
# musl flake output, one `<output><TAB><deps.drv>` line per output.
#
# WHY THIS EXISTS (order 765-8hc3). The deps derivations are `let`-bound inside
# flake.nix, so they are not flake outputs and cannot be named directly. Their
# STABILITY across source-only commits is the whole point of the packet: if a
# dep .drv changes while Cargo.lock did not, ~1,000 dependency crates recompile
# for nothing. This script makes that falsifiable — diff its output across two
# commits and any change is the regression.
#
# Resolution is structural, not by name-guessing: take the top-level
# derivation, walk its inputDrvs, and keep the one whose own environment marks
# it as a crane deps-only build (`cargoArtifacts`-producing derivations set
# CARGO_PROFILE and carry the `-deps` name suffix crane assigns).
#
# Routed through scripts/nix-toolbox.sh so it works on a host with no
# nix-daemon (operator toolbox directive 2026-08-16, order 777-amku).
#
# GRAMMAR (one line per output on stdout)
#   <flake-output><TAB>/nix/store/<hash>-<name>.drv
#   blocked:nix-deps-drv:<reason>
# Exit 0 when every requested output resolved, 1 otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

OUTPUTS=(
    tillandsias-x86_64-musl
    tillandsias-headless-x86_64-musl
    tillandsias-headless-aarch64-musl
    tillandsias-router-sidecar-x86_64-musl
)
[ "$#" -gt 0 ] && OUTPUTS=("$@")

NIX_ARGS=()
while IFS= read -r line; do
    [ -n "$line" ] && NIX_ARGS+=("$line")
done < <(bash "$ROOT/scripts/nix-toolbox.sh" nix-args 2>/dev/null)

_nix() {
    nix --extra-experimental-features "nix-command flakes" \
        ${NIX_ARGS[0]+"${NIX_ARGS[@]}"} "$@"
}

fail=0
for out in "${OUTPUTS[@]}"; do
    top_json="$(_nix derivation show ".#${out}" 2>/dev/null)" || {
        echo "blocked:nix-deps-drv:show-failed:${out}" >&2
        fail=1
        continue
    }
    # Two schema shapes in the wild, and BOTH are handled rather than assuming
    # this host's nix: newer nix wraps the map under `.derivations` and nests
    # the input derivations under `.inputs.drvs`; older nix emits the map at
    # top level with `.inputDrvs`. Guessing wrong yields an empty result that
    # looks exactly like "no deps derivation exists", which is the false
    # negative this script must never produce.
    #
    # crane names the buildDepsOnly output `<pname>-deps-<version>` (pname
    # defaults to `cargo-package` here since the deps calls set none), so
    # `-deps-` selects it. `vendor-cargo-deps.drv` — the vendored registry —
    # deliberately does NOT match: no trailing dash.
    deps="$(printf '%s' "$top_json" | jq -r '
        (if has("derivations") then .derivations else . end)
        | to_entries[0].value
        | ((.inputs.drvs // {}) + (.inputDrvs // {}))
        | keys[]
        | select(test("-deps-"))
    ' 2>/dev/null | head -n 1)"
    if [ -z "$deps" ]; then
        echo "blocked:nix-deps-drv:no-deps-input:${out}" >&2
        fail=1
        continue
    fi
    printf '%s\t%s\n' "$out" "$deps"
done
exit "$fail"
