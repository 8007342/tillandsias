#!/usr/bin/env bash
# @trace spec:methodology-accountability
# @trace order:1925-ided
#
# The v56.10.30.1 cut's gate refused litmus:claims-fleet-visible 9/22 on a tree
# whose standalone run was 27/27. With a shared CARGO_TARGET_DIR (1807-shtg)
# the fixture's scratch repos live under ANOTHER checkout's target/plan-scratch;
# the plan binary's cwd walk took that checkout as its validator surface, it
# sat behind the gated tree, and the pre-push hook refused every fixture push
# "the resolved plan binary is STALE". The fix: build.sh and local-ci.sh export
# TILLANDSIAS_SURFACE_ROOT=<the gating checkout> (a caller's value wins).
#
# Arms:
#   1. REPRODUCER: a shared target inside a different, OLDER checkout, no pin:
#      claims-fleet-visible refuses STALE. If this passes, the arm below would
#      prove nothing.
#   2. THE FIX: the pin, taken by evaluating the gate's OWN export line from
#      build.sh and from local-ci.sh (not re-typed here): claims-fleet-visible
#      passes. On the pre-fix tree neither line exists and this arm fails.
#   3. A caller's value is respected (the :- default, not an overwrite).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok:   $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

. scripts/plan-binary-probe.sh
BIN="$(resolve_plan_binary 2>/dev/null)" || BIN=""
case "$BIN" in ./*) BIN="$ROOT/${BIN#./}" ;; esac
if [ -z "$BIN" ] || ! "$BIN" validator-surface-hash >/dev/null 2>&1; then
    echo "skip:gate-pins-surface-root:no-validator — build it (cargo build --release -p tillandsias-plan)"
    exit 0
fi
if [ "$("$BIN" validator-surface-hash --check 2>/dev/null)" = "" ] \
   || ! "$BIN" validator-surface-hash --check >/dev/null 2>&1; then
    echo "FAIL: the resolved plan binary is stale against THIS checkout — rebuild first; the arms need a binary that is current here"
    exit 1
fi

base="${CARGO_TARGET_DIR:-$ROOT/target}"; case "$base" in /*) ;; *) base="$ROOT/$base" ;; esac
mkdir -p "$base/plan-scratch"
OLD="$(mktemp -d "$base/plan-scratch/gate-pins-surface-root.XXXXXX")" || { echo "FAIL: no scratch"; exit 1; }
trap 'rm -rf "$OLD"' EXIT INT TERM HUP PIPE

# The OLDER checkout: .git + the surface files, with one surface file changed
# so its hash differs from the one the binary was built from.
MANIFEST=crates/tillandsias-plan/validator-surface.manifest
mkdir -p "$OLD/.git"
for f in "$MANIFEST" Cargo.lock $(awk '/^file /{print $2}' "$MANIFEST"); do
    mkdir -p "$OLD/$(dirname "$f")" && cp "$f" "$OLD/$f" || { echo "FAIL: copy $f"; exit 1; }
done
printf '\n# 1925-ided: an older checkout\n' >> "$OLD/crates/tillandsias-plan/Cargo.toml"
mkdir -p "$OLD/target/release"
cp "$BIN" "$OLD/target/release/tillandsias-plan" || { echo "FAIL: copy binary"; exit 1; }

run_claims() {  # $1 = surface root to pin, or empty for none
    if [ -n "$1" ]; then
        env CARGO_TARGET_DIR="$OLD/target" TILLANDSIAS_SURFACE_ROOT="$1" \
            bash scripts/test-claims-fleet-visible.sh </dev/null 2>&1
    else
        env -u TILLANDSIAS_SURFACE_ROOT CARGO_TARGET_DIR="$OLD/target" \
            bash scripts/test-claims-fleet-visible.sh </dev/null 2>&1
    fi
}

# ── 1. reproducer ───────────────────────────────────────────────────────────
out="$(run_claims "")"
if grep -q '^FAIL: claims-fleet-visible' <<<"$out" \
   && grep -q 'resolved plan binary is STALE' <<<"$out"; then
    ok "unpinned, a shared target inside an older checkout makes claims-fleet-visible refuse STALE"
else
    bad "unpinned run did not refuse STALE — the reproducer does not reproduce: $(printf '%s\n' "$out" | grep -E '^(PASS|FAIL): claims' | tail -1)"
fi

# ── 2. the gate's own pin ───────────────────────────────────────────────────
gate_pin() {  # $1 file, $2 the root variable name that file uses
    local line
    line="$(grep -E '^export TILLANDSIAS_SURFACE_ROOT=' "$1" | head -1)"
    [ -n "$line" ] || return 1
    ( unset TILLANDSIAS_SURFACE_ROOT; eval "$2=\"\$ROOT\""; eval "$line"; printf '%s' "$TILLANDSIAS_SURFACE_ROOT" )
}
for pair in "build.sh SCRIPT_DIR" "scripts/local-ci.sh REPO_ROOT"; do
    set -- $pair
    pin="$(gate_pin "$1" "$2")" || pin=""
    if [ "$pin" != "$ROOT" ]; then
        bad "$1 does not export TILLANDSIAS_SURFACE_ROOT=<the gating checkout> (got '${pin}')"
        continue
    fi
    out="$(run_claims "$pin")"
    if grep -q '^PASS: claims-fleet-visible' <<<"$out"; then
        ok "$1's pin makes claims-fleet-visible pass under the same shared target"
    else
        bad "$1's pin did not make claims-fleet-visible pass: $(printf '%s\n' "$out" | grep -E '^(PASS|FAIL): claims' | tail -1)"
    fi
done

# ── 3. a caller's value wins ────────────────────────────────────────────────
line="$(grep -E '^export TILLANDSIAS_SURFACE_ROOT=' build.sh | head -1)"
got="$( TILLANDSIAS_SURFACE_ROOT=/caller/value; SCRIPT_DIR=/gate; eval "$line" 2>/dev/null; printf '%s' "${TILLANDSIAS_SURFACE_ROOT:-}" )"
if [ -n "$line" ] && [ "$got" = /caller/value ]; then
    ok "an existing TILLANDSIAS_SURFACE_ROOT is respected"
else
    bad "an existing TILLANDSIAS_SURFACE_ROOT was overwritten or the line is missing (got '$got')"
fi

echo "gate-pins-surface-root: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && { echo "PASS: gate-pins-surface-root $pass/$pass (1925-ided)"; exit 0; }
echo "FAIL: gate-pins-surface-root $pass/$((pass+fail)) (1925-ided)"; exit 1
