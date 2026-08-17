#!/usr/bin/env bash
# freshness: auditor=linux-macuahuitl-fable5-20260816t1140z date=2026-08-16 verdict=refreshed scope=fixture re-run live on linux 7/7 PASS (incl. case 7 stamp-demands-evidence); consumer wiring intact (build.sh invokes check-windows-only-sources-verified.sh at 2 sites, 716-f5kc report lane); no stale arm
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

# A transcript that looks like a clean cargo run. `stamp` demands one, because a
# stamp without evidence is an assertion (see the check's own grammar).
printf 'test some::thing ... ok
test result: ok. 1 passed; 0 failed
' > "$WORK/green.txt"
stamp() { run stamp --from "$WORK/green.txt"; }

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
out="$(stamp)"
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
stamp >/dev/null
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

# --- case 7 (NEGATIVE CONTROL): a stamp is a checked claim, not a courtesy ----
# The first version took the caller's word for it. Both refusals are proven
# reachable: no transcript at all, and a FAILED test nobody declared.
# case 6 removed the crate; put it back so this case has sources to stamp.
mkdir -p "$SRC/stubs"
cat > "$SRC/main.rs" <<'RS'
#[cfg(target_os = "windows")]
mod hvsocket;
#[cfg(target_os = "windows")]
mod wsl_lifecycle;
RS
echo "// windows only" > "$SRC/hvsocket.rs"
echo "// windows only" > "$SRC/wsl_lifecycle.rs"
out="$(run stamp 2>/dev/null)"
case "$out" in
    refused:stamp-needs-evidence:*) ;;
    *) fail "case 7: a bare stamp must refuse, got '$out'" ;;
esac
printf 'test a::b ... ok
test a::undeclared_red ... FAILED
' > "$WORK/red.txt"
out="$(run stamp --from "$WORK/red.txt" 2>/dev/null)"
[ "$out" = "refused:undeclared-failure:undeclared_red" ]     || fail "case 7: an undeclared red must refuse and name the test, got '$out'"
printf 'undeclared_red
' > "$WORK/scripts/windows-only-known-red.txt" 2>/dev/null || {
    mkdir -p "$WORK/scripts"; printf 'undeclared_red
' > "$WORK/scripts/windows-only-known-red.txt"; }
out="$(run stamp --from "$WORK/red.txt")"
[ "$out" = "ok:windows-sources-verified:2" ]     || fail "case 7: a DECLARED red must be tolerated, got '$out'"
echo "ok: case 7 — the stamp demands evidence and refuses undeclared reds"

# --- case 8: THE REFUSAL'S OWN COMMAND SHAPE MUST BE ACCEPTED (order 801-ajcd)
# Self-referential on purpose, and the only form that cannot drift: the argv is
# EXTRACTED from the live refusal text and then EXECUTED. A message that says
# one thing while the parser wants another turns this red, which is exactly what
# happened for weeks — the text read `pass --from <cargo-test-output>`, so
# obeying it verbatim produced `stamp pass --from …` and was refused again.
rm -f "$WORK/stamp"
refusal="$(run stamp 2>/dev/null)"
case "$refusal" in
    refused:stamp-needs-evidence:usage:*) ;;
    *) fail "case 8: the bare-stamp refusal must carry a 'usage: <argv>' shape, got '$refusal'" ;;
esac
# Everything between `usage: ` and the first `;` is the claimed argv.
claimed="${refusal#*usage: }"
claimed="${claimed%%;*}"
# Drop argv[0] (the script name) and the <placeholder>, substitute the real
# transcript, and run what the message told the reader to run.
claimed_args="${claimed#* }"
claimed_args="${claimed_args%% <*}"
# shellcheck disable=SC2086
out="$(run $claimed_args "$WORK/green.txt")"
[ "$out" = "ok:windows-sources-verified:2" ] \
    || fail "case 8: the refusal's own argv ('$claimed_args <file>') was not accepted by the parser, got '$out'"
# The literal pre-801-ajcd wording is still answered rather than refused twice —
# scripts and transcripts written from it during those weeks keep working.
rm -f "$WORK/stamp"
out="$(run stamp pass --from "$WORK/green.txt")"
[ "$out" = "ok:windows-sources-verified:2" ] \
    || fail "case 8: the legacy 'stamp pass --from <file>' form must be tolerated, got '$out'"
# NEGATIVE CONTROL: tolerating `pass` must not have made evidence optional.
rm -f "$WORK/stamp"
out="$(run stamp pass 2>/dev/null)"
case "$out" in
    refused:stamp-needs-evidence:usage:*) ;;
    *) fail "case 8 negative control: 'stamp pass' with no --from must still refuse, got '$out'" ;;
esac
out="$(run stamp --from 2>/dev/null)"
case "$out" in
    refused:stamp-needs-evidence:usage:*) ;;
    *) fail "case 8 negative control: '--from' with no path must still refuse, got '$out'" ;;
esac
echo "ok: case 8 — the refusal's own command shape parses, and evidence stays mandatory"

echo "PASS: windows-only source verification report (8/8)"
