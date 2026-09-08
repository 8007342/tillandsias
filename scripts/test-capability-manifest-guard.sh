#!/usr/bin/env bash
# @trace spec:forge-environment-discoverability
# @trace order:583-dv9n, order:1114-p2ht
# Build the compile-time capability-manifest cases in a private source copy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Keep the shared probe in scope: this fixture intentionally executes its
# private, freshly-built artifacts below, rather than a host target/ artifact.
. "$ROOT/scripts/plan-binary-probe.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/litmus-583.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO"
cp -a "$ROOT/Cargo.toml" "$ROOT/Cargo.lock" "$ROOT/crates" "$ROOT/assets" "$ROOT/images" "$REPO/"
[ ! -d "$ROOT/.cargo" ] || cp -a "$ROOT/.cargo" "$REPO/"

MANIFEST="$REPO/crates/tillandsias-plan/capabilities.txt"
grep -v '^query$' "$MANIFEST" > "$WORK/trimmed.txt"
mv "$WORK/trimmed.txt" "$MANIFEST"
CARGO_TARGET_DIR="$WORK/target" cargo build -q --manifest-path "$REPO/Cargo.toml" -p tillandsias-plan --release
DRIFTED="$WORK/target/release/tillandsias-plan"
[ -x "$DRIFTED" ] || { echo "FAIL: no drifted tillandsias-plan artifact"; exit 1; }
echo "ok: fixture-drifted-built"

rc=0
"$DRIFTED" capabilities >"$WORK/drifted.out" 2>"$WORK/drifted.err" || rc=$?
want=$(( $(grep -cE '^[a-z][a-z0-9-]*$' "$ROOT/crates/tillandsias-plan/capabilities.txt") - 1 ))
[ "$rc" = 0 ] || { echo "FAIL: drifted capabilities exited $rc"; exit 1; }
grep -q "warning: dispatch arm 'query' is not listed in capabilities.txt" "$WORK/drifted.err" || { echo "FAIL: drift warning absent"; exit 1; }
grep -q 'order 583-dv9n' "$WORK/drifted.err" || { echo "FAIL: drift warning lacks order"; exit 1; }
! grep -q '^query$' "$WORK/drifted.out" || { echo "FAIL: drifted stdout still lists query"; exit 1; }
! grep -qvE '^[a-z][a-z0-9-]*$' "$WORK/drifted.out" || { echo "FAIL: drifted stdout is not a token stream"; exit 1; }
[ "$(wc -l < "$WORK/drifted.out")" = "$want" ] || { echo "FAIL: drifted token count differs"; exit 1; }
echo "ok: drift-warns-on-stderr-no-gate"

mkdir -p "$WORK/checkout/crates/tillandsias-plan"
cp "$ROOT/crates/tillandsias-plan/capabilities.txt" "$WORK/checkout/crates/tillandsias-plan/capabilities.txt"
line="$(FORGE_EXPERTS_STATE_DIR="$WORK/state" sh "$ROOT/images/default/lib-expert-capability.sh" "$DRIFTED" "$WORK/checkout")"
line="$(printf '%s\n' "$line" | sed -n '1p')"
case "$line" in
    *'now=answer,append-event'*'blocked_capabilities=query'*) ;;
    *) echo "FAIL: under-report did not remain fail-safe: $line"; exit 1 ;;
esac
echo "ok: under-report-failsafe"

cp "$ROOT/crates/tillandsias-plan/capabilities.txt" "$MANIFEST"
CARGO_TARGET_DIR="$WORK/target" cargo build -q --manifest-path "$REPO/Cargo.toml" -p tillandsias-plan --release
CLEAN="$WORK/target/release/tillandsias-plan"
"$CLEAN" capabilities >"$WORK/clean.out" 2>"$WORK/clean.err"
[ ! -s "$WORK/clean.err" ] || { echo "FAIL: clean artifact wrote stderr: $(head -c 160 "$WORK/clean.err")"; exit 1; }
want="$(grep -cE '^[a-z][a-z0-9-]*$' "$ROOT/crates/tillandsias-plan/capabilities.txt")"
[ "$(wc -l < "$WORK/clean.out")" = "$want" ] || { echo "FAIL: clean token count differs"; exit 1; }
grep -q '^query$' "$WORK/clean.out" || { echo "FAIL: clean artifact lacks query"; exit 1; }
echo "ok: clean-tree-silent"
echo "PASS: capability manifest guard (4/4)"
