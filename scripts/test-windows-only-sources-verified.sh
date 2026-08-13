#!/usr/bin/env bash
# @trace spec:windows-native-tray, spec:methodology-accountability
#
# Fixture for scripts/check-windows-only-sources-verified.sh (order 716-f5kc).
#
# The checker exists because a Linux build of the Windows tray compiles STUBS
# and goes green without reading the edited file. A checker for that which
# cannot itself be seen to fail would be the same failure one level up, so every
# verdict is proven reachable here on a throwaway tree.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-windows-only-sources-verified.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$CHECK" ] || fail "checker not found: $CHECK"

SRC="$WORK/crates/tillandsias-windows-tray/src"
mkdir -p "$SRC/stubs"
cat > "$SRC/main.rs" <<'RS'
#[cfg(target_os = "windows")]
mod hvsocket;
#[cfg(target_os = "windows")]
mod wsl_lifecycle;
mod portable_thing;

#[cfg(not(target_os = "windows"))]
#[path = "stubs/wsl_lifecycle.rs"]
mod wsl_lifecycle;
RS
echo "// windows only" > "$SRC/hvsocket.rs"
echo "// windows only" > "$SRC/wsl_lifecycle.rs"
echo "// portable" > "$SRC/portable_thing.rs"

run() { WINDOWS_ONLY_ROOT="$WORK" WINDOWS_ONLY_STAMP="$WORK/stamp" bash "$CHECK" "$@"; }

# --- case 1: no stamp yet is reported, not assumed fine ----------------------
out="$(run check)"
[ "$out" = "stale:windows-sources-never-verified:2" ] \
    || fail "case 1: an unstamped host must say so, got '$out'"
echo "ok: case 1 — never-verified is a verdict, not silence"

# --- case 2: the set is DERIVED, and includes a module with no stub ----------
# hvsocket has no `#[path = "stubs/…"]` line. The first version of the checker
# read the stub declarations and silently missed it — a Windows-only module
# that is just as invisible to a Linux build.
[ "$out" = "stale:windows-sources-never-verified:2" ] \
    || fail "case 2: expected both windows-only modules, got '$out'"
echo "ok: case 2 — a stubless windows-only module is still counted"

# --- case 3: stamping makes it verified --------------------------------------
out="$(run stamp)"
[ "$out" = "ok:windows-sources-verified:2" ] || fail "case 3: stamp said '$out'"
out="$(run check)"
[ "$out" = "ok:windows-sources-verified:2" ] || fail "case 3: check after stamp said '$out'"
echo "ok: case 3 — a stamped tree verifies"

# --- case 4 (NEGATIVE CONTROL): an edit goes stale and NAMES the file --------
# This is the whole point. Editing a windows-only source on a Linux host is
# exactly the move that produces a meaningless green.
echo "// edited on a host that cannot compile it" >> "$SRC/wsl_lifecycle.rs"
out="$(run check)"
case "$out" in
    stale:windows-sources-unverified:*wsl_lifecycle.rs) ;;
    *) fail "case 4: an edited windows-only source must go stale and be named, got '$out'" ;;
esac
echo "ok: case 4 — an edit goes stale and the file is named"

# --- case 5 (NEGATIVE CONTROL): a PORTABLE edit does not go stale ------------
# Without this the check could pass case 4 by reporting stale for any change at
# all, which would make it noise within a day and then be ignored.
run stamp >/dev/null
echo "// portable edit" >> "$SRC/portable_thing.rs"
out="$(run check)"
[ "$out" = "ok:windows-sources-verified:2" ] \
    || fail "case 5: a portable-source edit must NOT go stale, got '$out'"
echo "ok: case 5 — portable edits are not reported (the check stays quiet when it should)"

# --- case 6: a crate that is not there at all ---------------------------------
rm -rf "$WORK/crates"
out="$(run check)"
[ "$out" = "skip:no-windows-only-sources" ] \
    || fail "case 6: a missing crate must skip, got '$out'"
echo "ok: case 6 — nothing to check is said out loud too"

echo "PASS: windows-only source verification report (6/6)"
