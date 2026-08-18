#!/usr/bin/env bash
# @trace order:797-8dzt
#
# Fixture for check-source-slice-bounds.sh. Three scenarios, and scenario 2 is
# the one that matters: it FAILED on the guard's first draft, because a plain
# fixed-string search for the needle found it inside the very `.split("…")`
# call under test. Every bound resolved to itself and the guard was vacuous —
# the exact shape of the defect it exists to catch, reproduced in the catcher.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-source-slice-bounds.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — want rc=$2 got rc=$3" >&2; fail=1; fi; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/slice-bounds-fixture.XXXXXX")"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/mycrate/src"; : > "$SB/mycrate/Cargo.toml"

# 1. A bound naming a symbol that EXISTS must pass.
printf 'fn real_one() {}\nfn other() {}\n#[test]\nfn t() { let s = include_str!("lib.rs"); let _ = s.split("fn real_one").nth(1); }\n' \
    > "$SB/mycrate/src/lib.rs"
TILLANDSIAS_SLICE_BOUND_ROOT="$SB" bash "$GUARD" >/dev/null 2>&1
check "live-bound-passes" 0 "$?"

# 2. A bound naming a symbol that exists NOWHERE must be caught. Non-vacuity of
#    the whole guard rests on this one.
sed -i 's/s.split("fn real_one")/s.split("fn vanished_neighbour")/' "$SB/mycrate/src/lib.rs"
TILLANDSIAS_SLICE_BOUND_ROOT="$SB" bash "$GUARD" >/dev/null 2>&1
check "dead-bound-is-caught" 1 "$?"

# 3. NEGATIVE CONTROL against over-accusation: a slice may legitimately bound on
#    a symbol declared in a SIBLING file of the same crate (include_str! of
#    another module). Crate-scoped resolution must not call that dead.
printf 'pub fn helper_symbol() {}\n' > "$SB/mycrate/src/other.rs"
sed -i 's/s.split("fn vanished_neighbour")/s.split("pub fn helper_symbol")/' "$SB/mycrate/src/lib.rs"
TILLANDSIAS_SLICE_BOUND_ROOT="$SB" bash "$GUARD" >/dev/null 2>&1
check "cross-file-bound-not-accused" 0 "$?"

if [ "$fail" -eq 0 ]; then echo "ok: source-slice-bounds 3/3"; exit 0; fi
echo "FAIL: source-slice-bounds had failures"; exit 1
