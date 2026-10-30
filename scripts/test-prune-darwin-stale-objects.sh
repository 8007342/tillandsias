#!/usr/bin/env bash
# Fixture for scripts/prune-darwin-stale-objects.sh (order 1924-dobj).
# A loose .o group with its executable beside it is kept; a group with no
# executable (a library, whose code is in its rlib) is pruned; nothing that
# is not a .rcgu.o is touched; a second run prunes nothing.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prune="$here/prune-darwin-stale-objects.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
deps="$work/debug/deps"
mkdir -p "$deps"

fail=0
check() { if eval "$2"; then echo "  ok: $1"; else echo "  FAIL: $1"; fail=1; fi; }

exe=demo_tests-0123456789abcdef
lib=demo_lib-fedcba9876543210
: >"$deps/$exe"; chmod +x "$deps/$exe"
for i in 1 2 3; do
    : >"$deps/$exe.cgu$i.s1.rcgu.o"
    : >"$deps/$lib.cgu$i.s1.rcgu.o"
done
: >"$deps/lib$lib.rlib"; : >"$deps/$lib.d"; : >"$deps/lib$lib.rmeta"

out="$("$prune" "$deps")"
check "reports three files in one pruned group, one kept" '[[ "$out" == "pruned:darwin-stale-objects:files=3 groups=1 kept=1" ]]'
check "the executable's own objects are kept" '[[ -f "$deps/$exe.cgu1.s1.rcgu.o" && -f "$deps/$exe.cgu3.s1.rcgu.o" ]]'
check "the library's loose objects are pruned" '! ls "$deps" | grep -q "^$lib\..*\.rcgu\.o$"'
check "rlib, rmeta and dep-info are untouched" '[[ -f "$deps/lib$lib.rlib" && -f "$deps/lib$lib.rmeta" && -f "$deps/$lib.d" ]]'
again="$("$prune" "$deps")"
check "a second run prunes nothing" '[[ "$again" == "pruned:darwin-stale-objects:files=0 groups=0 kept=1" ]]'

if (( fail )); then
    echo "FAIL: prune-darwin-stale-objects fixture (1924-dobj)"
    exit 1
fi
echo "ok:prune-darwin-stale-objects:5"
