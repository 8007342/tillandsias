#!/usr/bin/env bash
# @trace order:765-8hc3, spec:ci-release
#
# check-nix-deps-stability.sh — assert the crane DEPS derivations do not move
# when only SOURCE changes.
#
# THE INVARIANT. `nix build .#tillandsias-*-musl` splits into a deps-only
# derivation (~1,000 vendored crates, two musl targets) and a thin workspace
# build on top. If the deps derivation's hash moves on an ordinary commit, every
# release and every `--ci-full --install` cold-compiles that whole dependency
# set again — the largest event-scoped compute sink in the loop.
#
# WHAT ORDER 765-8hc3 ACTUALLY FOUND. The velocity audit's finding F7 inferred,
# from `commonCraneArgs.src = craneSrc` being the full tree, that all four
# `buildDepsOnly` calls churn on any file change. MEASURED 2026-08-17, that is
# FALSE: crane's `buildDepsOnly` runs its `src` through `mkDummySrc`, which
# keeps the dependency-defining inputs and stubs the rest, so the deps
# derivations are ALREADY stable. Evidence recorded on the packet:
#
#   source-only edit  -> top-level drv CHANGED, deps drv UNCHANGED   (desired)
#   Cargo.toml metadata -> deps drv UNCHANGED   (crane normalizes it)
#   Cargo.lock edit   -> deps drv CHANGED       (dependency graph moved)
#
# So there was nothing to fix — and that is exactly why this check exists. The
# property is load-bearing, currently TRUE, and completely unprotected: a future
# `preBuild`, `extraDummyScript`, or a well-meant "just pass the real src"
# refactor would silently restore the 10-30 minute cold rebuild with no signal.
# A guard is worth more here than a change.
#
# WHY A PROPERTY TEST AND NOT A COMMITTED BASELINE. A baseline of expected .drv
# hashes drifts with nixpkgs, crane, the nix version and the host, so it would
# false-red on hosts that are perfectly fine — and a guard that cries wolf gets
# switched off (the 741-2izr lesson). This instead PERTURBS the tree and asserts
# the invariant directly, so it is host-independent and needs no maintenance.
#
# NON-VACUITY IS ENFORCED, NOT ASSUMED. If the perturbation does not move the
# TOP-LEVEL derivation, the probe cannot see source changes at all (dirty-tree
# handling, a filter change, an eval cache) and every comparison below would
# pass for the wrong reason. That case fails LOUD rather than reporting ok.
#
# Routed through scripts/nix-toolbox.sh, so a host with no nix-daemon still runs
# it (operator toolbox directive 2026-08-16; orders 777-amku / 736-mcy3).
#
# GRAMMAR (exactly one line on stdout)
#   ok:nix-deps-stable:<n> checked
#   violation:nix-deps-churn:<output>[,<output>...]
#   violation:nix-deps-probe-vacuous:<output>
#   skip:nix-deps-stability:<no-nix|nix-unusable|no-perturbable-source>
# Exit 0 on ok/skip, 1 on violation, 2 on usage error.
#
# USAGE
#   scripts/check-nix-deps-stability.sh            # one representative output
#   scripts/check-nix-deps-stability.sh --all      # all four musl outputs

set -uo pipefail


# ORDER 799-tb7q — resolve `jq` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has it.
# shellcheck source=scripts/lib/tool-dispatch.sh
# Resolve the lib by WALKING UP, not by a fixed depth (order 914-ahsy). The
# fixed form `dirname "${BASH_SOURCE[0]}"/lib/...` is correct only for a caller
# sitting directly in scripts/. From scripts/refusal-calibration/ it points at a
# lib that does not exist, the `|| true` swallows the miss, and the tool variable
# silently falls back to the bare name — a conversion that passes review, passes
# the suite, and changes nothing.
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
if command -v resolve_tool >/dev/null 2>&1; then
    JQ="$(resolve_tool jq || printf 'jq')"
else
    JQ="jq"   # lib unavailable: preserve the previous behaviour exactly
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# One representative output by default: each extra output costs two full flake
# evaluations, and the invariant is a property of commonCraneArgs shared by all
# four. --all is the thorough lane for a release gate.
OUTPUTS=(tillandsias-headless-x86_64-musl)
case "${1:-}" in
    --all)
        OUTPUTS=(
            tillandsias-x86_64-musl
            tillandsias-headless-x86_64-musl
            tillandsias-headless-aarch64-musl
            tillandsias-router-sidecar-x86_64-musl
        )
        ;;
    "") : ;;
    *) echo "usage: $(basename "$0") [--all]" >&2; exit 2 ;;
esac

command -v nix >/dev/null 2>&1 || { echo "skip:nix-deps-stability:no-nix"; exit 0; }

NIX_ARGS=()
while IFS= read -r line; do
    [ -n "$line" ] && NIX_ARGS+=("$line")
done < <(bash "$ROOT/scripts/nix-toolbox.sh" nix-args 2>/dev/null)

_nix() {
    nix --extra-experimental-features "nix-command flakes" \
        ${NIX_ARGS[0]+"${NIX_ARGS[@]}"} "$@"
}

_nix store ping >/dev/null 2>&1 || { echo "skip:nix-deps-stability:nix-unusable"; exit 0; }

# `derivation show` for one output, reduced to (top-level drv, deps drv).
# Both schema shapes are handled: newer nix nests under .derivations/.inputs.drvs,
# older uses a top-level map with .inputDrvs.
probe() { # <output> -> "<top>\t<deps>"
    local out="$1" json top deps
    json="$(_nix derivation show ".#${out}" 2>/dev/null)" || return 1
    top="$(printf '%s' "$json" | "$JQ" -r '
        (if has("derivations") then .derivations else . end) | keys[0]' 2>/dev/null)"
    deps="$(printf '%s' "$json" | "$JQ" -r '
        (if has("derivations") then .derivations else . end)
        | to_entries[0].value
        | ((.inputs.drvs // {}) + (.inputDrvs // {}))
        | keys[] | select(test("-deps-"))' 2>/dev/null | head -n 1)"
    [ -n "$top" ] && [ -n "$deps" ] || return 1
    printf '%s\t%s\n' "$top" "$deps"
}

# Perturb a TRACKED source file that is inside craneSrc but is not a manifest.
# Restored unconditionally on every exit path, including a fatal signal — this
# script must never leave the tree dirty.
PERTURB="crates/tillandsias-headless/src/main.rs"
[ -f "$PERTURB" ] || { echo "skip:nix-deps-stability:no-perturbable-source"; exit 0; }
git -C "$ROOT" diff --quiet -- "$PERTURB" 2>/dev/null || {
    # A pre-dirty perturbation target would be restored to HEAD by our cleanup
    # and silently discard someone's edit. Refuse the check instead.
    echo "skip:nix-deps-stability:no-perturbable-source"
    exit 0
}
restore() { git -C "$ROOT" checkout -- "$PERTURB" 2>/dev/null || true; }
trap restore EXIT HUP INT TERM

declare -a BEFORE_TOP BEFORE_DEPS
i=0
for out in "${OUTPUTS[@]}"; do
    if ! line="$(probe "$out")"; then
        echo "skip:nix-deps-stability:nix-unusable"
        exit 0
    fi
    BEFORE_TOP[$i]="${line%%	*}"
    BEFORE_DEPS[$i]="${line##*	}"
    i=$((i + 1))
done

printf '\n// check-nix-deps-stability transient perturbation (order 765-8hc3)\n' >> "$PERTURB"

churned=""
vacuous=""
i=0
for out in "${OUTPUTS[@]}"; do
    if ! line="$(probe "$out")"; then
        echo "skip:nix-deps-stability:nix-unusable"
        exit 0
    fi
    after_top="${line%%	*}"
    after_deps="${line##*	}"
    if [ "$after_top" = "${BEFORE_TOP[$i]}" ]; then
        vacuous="${vacuous}${vacuous:+,}${out}"
    elif [ "$after_deps" != "${BEFORE_DEPS[$i]}" ]; then
        churned="${churned}${churned:+,}${out}"
    fi
    i=$((i + 1))
done

restore
trap - EXIT HUP INT TERM

if [ -n "$vacuous" ]; then
    echo "violation:nix-deps-probe-vacuous:${vacuous}"
    echo "  the perturbation did not move the top-level derivation, so this check" >&2
    echo "  cannot observe source changes and its ok verdict would be meaningless." >&2
    echo "  Look at craneSrc's filter, dirty-tree handling, or an eval cache." >&2
    exit 1
fi
if [ -n "$churned" ]; then
    echo "violation:nix-deps-churn:${churned}"
    echo "  A SOURCE-ONLY change moved the crane deps derivation for the outputs" >&2
    echo "  above. Every release and --ci-full --install will now cold-compile" >&2
    echo "  ~1,000 dependency crates per target (10-30 min) instead of reusing" >&2
    echo "  them. Usual cause: buildDepsOnly stopped going through crane's" >&2
    echo "  mkDummySrc — e.g. an added preBuild/extraDummyScript, or src being" >&2
    echo "  passed straight through. See order 765-8hc3." >&2
    exit 1
fi

echo "ok:nix-deps-stable:${#OUTPUTS[@]} checked"
exit 0
