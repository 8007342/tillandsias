#!/usr/bin/env bash
# @trace order:797-8dzt, order:1528-ekri
#
# Fixture for check-source-slice-bounds.lua. Three scenarios, and scenario 2 is
# the one that matters: it FAILED on the guard's first draft, because a plain
# fixed-string search for the needle found it inside the very `.split("…")`
# call under test. Every bound resolved to itself and the guard was vacuous —
# the exact shape of the defect it exists to catch, reproduced in the catcher.
#
# PORTED to Lua (1528-ekri): the guard is scripts/lua/check-source-slice-bounds.lua,
# run through the one runner; no runner is a loud skip, never a silent pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAN_BIN="$(cd "$ROOT" && . scripts/plan-binary-probe.sh 2>/dev/null && resolve_plan_binary 2>/dev/null)" || PLAN_BIN=""
case "$PLAN_BIN" in ./*) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac
if [ -z "$PLAN_BIN" ] || ! grep -qx script <<<"$("$PLAN_BIN" capabilities 2>/dev/null)"; then
    echo "skip:source-slice-bounds-fixture:no-script-runner — no tillandsias-plan with \`script run\` resolves; rebuild it (cargo build --release -p tillandsias-plan)"
    exit 0
fi
GUARD_LUA="$ROOT/scripts/lua/check-source-slice-bounds.lua"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 — want rc=$2 got rc=$3" >&2; fail=1; fi; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/slice-bounds-fixture.XXXXXX")"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/mycrate/src"; : > "$SB/mycrate/Cargo.toml"

# 1. A bound naming a symbol that EXISTS must pass.
printf 'fn real_one() {}\nfn other() {}\n#[test]\nfn t() { let s = include_str!("lib.rs"); let _ = s.split("fn real_one").nth(1); }\n' \
    > "$SB/mycrate/src/lib.rs"
TILLANDSIAS_SLICE_BOUND_ROOT="$SB" "$PLAN_BIN" script run "$GUARD_LUA" >/dev/null 2>&1
check "live-bound-passes" 0 "$?"

# 2. A bound naming a symbol that exists NOWHERE must be caught. Non-vacuity of
#    the whole guard rests on this one.
# 1135-z8gn: temp-file form, portable on both dialects.
sed 's/s.split("fn real_one")/s.split("fn vanished_neighbour")/' "$SB/mycrate/src/lib.rs" > "$SB/lib.rs.tmp" && mv "$SB/lib.rs.tmp" "$SB/mycrate/src/lib.rs"
TILLANDSIAS_SLICE_BOUND_ROOT="$SB" "$PLAN_BIN" script run "$GUARD_LUA" >/dev/null 2>&1
check "dead-bound-is-caught" 1 "$?"

# 3. NEGATIVE CONTROL against over-accusation: a slice may legitimately bound on
#    a symbol declared in a SIBLING file of the same crate (include_str! of
#    another module). Crate-scoped resolution must not call that dead.
printf 'pub fn helper_symbol() {}\n' > "$SB/mycrate/src/other.rs"
# 1135-z8gn: temp-file form, portable on both dialects.
sed 's/s.split("fn vanished_neighbour")/s.split("pub fn helper_symbol")/' "$SB/mycrate/src/lib.rs" > "$SB/lib.rs.tmp" && mv "$SB/lib.rs.tmp" "$SB/mycrate/src/lib.rs"
TILLANDSIAS_SLICE_BOUND_ROOT="$SB" "$PLAN_BIN" script run "$GUARD_LUA" >/dev/null 2>&1
check "cross-file-bound-not-accused" 0 "$?"

if [ "$fail" -eq 0 ]; then echo "ok: source-slice-bounds 3/3"; exit 0; fi
echo "FAIL: source-slice-bounds had failures"; exit 1
