#!/usr/bin/env bash
# @trace order:1459-b5fh, spec:cheatsheet-tooling
#
# The cheatsheet INDEX is generated and COMMITTED, so its bytes must not
# depend on the host. They did: the generator delegated collation to the
# platform's `sort`, so glibc en_US, the MSYS/Cygwin runtime and a C locale
# each produced a different order (and on Windows a bare `sort` even ran
# System32's sort.exe). It now sorts in Rust by byte order.
#
#   1  under LC_ALL=C the committed INDEX is current (--check exits 0)
#   2  under LC_ALL=en_US.UTF-8 it is current too: the locale changes nothing
#   3  the pinned pair: podman-control-plane.md precedes podman.md ('-' 0x2D
#      sorts before '.' 0x2E), the pair glibc and Cygwin disagree on
#
# The helpers themselves (byte order, dedup, stability, no external sort) are
# pinned by tillandsias-policy's unit tests; the other two outputs that use
# them (distill-forge-diagnostics' stage states, the bundled-tier fetch key)
# read no environment, so they share the same determinism.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGEN="$ROOT/scripts/regenerate-cheatsheet-index.sh"
IDX="$ROOT/cheatsheets/INDEX.md"
[ -f "$REGEN" ] && [ -f "$IDX" ] || { echo "skip:cheatsheet-index-byte-order:absent"; exit 0; }
command -v cargo >/dev/null 2>&1 || { echo "skip:cheatsheet-index-byte-order:no-cargo"; exit 0; }
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

for loc in C en_US.UTF-8; do
    out="$(cd "$ROOT" && LC_ALL="$loc" bash "$REGEN" --check 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "the committed INDEX is current under LC_ALL=$loc"
    else
        bad "under LC_ALL=$loc the INDEX would change (rc=$rc): $(printf '%s' "$out" | tail -2 | tr '\n' ';')"
    fi
done

a="$(grep -n '^- podman-control-plane\.md ' "$IDX" | head -1 | cut -d: -f1)"
b="$(grep -n '^- podman\.md ' "$IDX" | head -1 | cut -d: -f1)"
if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then
    ok "podman-control-plane.md (line $a) precedes podman.md (line $b): byte order"
else
    bad "pinned pair out of byte order or missing: podman-control-plane.md=${a:-absent} podman.md=${b:-absent}"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "ok:cheatsheet-index-byte-order:$pass"; exit 0; fi
echo "violation:cheatsheet-index-byte-order:$pass/$total"; exit 1
