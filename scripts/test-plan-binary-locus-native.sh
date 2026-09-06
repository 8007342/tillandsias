#!/usr/bin/env bash
# @trace order:1030-i2p8
#
# test-plan-binary-locus-native.sh — the probe must resolve the artefact NATIVE
# to the locus it runs in, when both artefacts are present.
#
# THE DEFECT. On a shared Windows/WSL checkout both target/release/
# tillandsias-plan (ELF) and tillandsias-plan.exe exist. resolve_plan_binary
# tried the .exe FIRST, and inside the tillandsias-build WSL2 distro with
# interop enabled the .exe RUNS — so the probe returned the .exe while
# ensure_fresh_plan_binary rebuilt and touched the ELF. The thing touched was
# not the thing resolved, the .exe stayed stale forever, and every floor gate
# refused at `blocked:fragment-events-land:no-fresh-plan-binary` without ever
# completing. Measured on esmeraldinha 2026-09-04: gate6 exit=1 at 7m58s.
#
# WHY A FIXTURE AND NOT A HOST CHECK. The condition is currently MASKED on the
# only host that has it — interop is disabled in that distro today, so a .exe
# there exits 126 and the probe already falls through. A host check would pass
# for the wrong reason and would stop passing the moment someone enables
# interop, which is a per-distro setting nobody has to touch this repo to
# change. So both artefacts are SYNTHESISED here and both are made runnable,
# which is the interop-enabled world, on any host.
#
# Arm 2 is the control: it runs the OLD candidate order against the same tree
# and requires it to pick the .exe. Without it, arm 1 would pass on a tree where
# the ordering had never been fixed — it would just be reporting that the ELF
# comes first in a list nobody changed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/plan-locus.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
mkdir -p "$W/target/release" "$W/crates/tillandsias-plan/src"

# Both artefacts present and BOTH runnable — the interop-enabled world.
for n in tillandsias-plan tillandsias-plan.exe; do
    printf '#!/bin/sh\n[ "$1" = capabilities ] && { echo append-event; exit 0; }\nexit 1\n' > "$W/target/release/$n"
    chmod +x "$W/target/release/$n"
done
# Sources NEWER than the .exe, which is what a `git pull` produces and what the
# staleness predicate keys on.
printf 'fn main() {}\n' > "$W/crates/tillandsias-plan/src/main.rs"
touch -d '+1 hour' "$W/crates/tillandsias-plan/src/main.rs" 2>/dev/null \
  || touch -A '0100' "$W/crates/tillandsias-plan/src/main.rs" 2>/dev/null || true

# shellcheck disable=SC1090
. "$ROOT/scripts/plan-binary-probe.sh"

# ── 1. THE FIX: with both runnable, the LOCUS-NATIVE artefact wins.
( cd "$W" && unset CARGO_TARGET_DIR && resolve_plan_binary ) > "$W/got" 2>/dev/null
got="$(cat "$W/got" 2>/dev/null)"
case "$got" in
    *tillandsias-plan.exe) bad "the probe resolved the .exe with a runnable ELF present — the shared-checkout defect (1030-i2p8): $got" ;;
    *tillandsias-plan)     ok  "with both artefacts runnable, the probe resolves the locus-native ELF ($got)" ;;
    *)                     bad "the probe resolved nothing or something unexpected: '${got:-<empty>}'" ;;
esac

# ── 2. CONTROL: the OLD order picks the .exe on the SAME tree. Without this,
#      arm 1 proves only that a list is in some order, not that it was fixed.
old_order_pick() {
    local c
    for c in ./target/release/tillandsias-plan.exe ./target/debug/tillandsias-plan.exe \
             ./target/release/tillandsias-plan ./target/debug/tillandsias-plan; do
        [ -f "$c" ] || continue
        "$c" capabilities >/dev/null 2>&1 || continue
        printf '%s\n' "$c"; return 0
    done
    return 1
}
oldgot="$( cd "$W" && old_order_pick 2>/dev/null )"
case "$oldgot" in
    *tillandsias-plan.exe) ok "CONTROL: the pre-fix order picks the .exe on this same tree — arm 1 has teeth" ;;
    *) bad "CONTROL failed: the pre-fix order did not pick the .exe ('$oldgot'); arm 1 may be passing for the wrong reason" ;;
esac

# ── 3. THE OTHER LOCUS: when the ELF cannot execute — the Windows side, where
#      an in-tree ELF from a sibling WSL build sits next to the real .exe — the
#      probe must fall through to the .exe rather than resolving nothing.
printf '\177ELF not-runnable-here\n' > "$W/target/release/tillandsias-plan"
chmod +x "$W/target/release/tillandsias-plan"
got2="$( cd "$W" && unset CARGO_TARGET_DIR && resolve_plan_binary 2>/dev/null )"
case "$got2" in
    *tillandsias-plan.exe) ok "when the ELF cannot execute, the probe falls through to the .exe ($got2)" ;;
    *) bad "with an unrunnable ELF the probe returned '${got2:-<empty>}' instead of the .exe — ordering must not strand the Windows locus" ;;
esac

echo "plan-binary-locus-native: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
