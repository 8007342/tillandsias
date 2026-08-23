#!/usr/bin/env bash
# @trace order:851-gpb5
#
# Fixture for gate-stamp.sh's portable SHA-256 dispatch (order 851-gpb5).
#
# WHAT WAS BROKEN. gate-stamp.sh called bare `sha256sum` at four sites.
# coreutils ships it on Linux/forge/WSL; Apple only added /sbin/sha256sum in
# macOS 13, and a Mac on 12-or-older (or any PATH without /sbin) has only
# `shasum`. There the failure is SILENT in the worst way: compute fails,
# build.sh:1468 discards memo-check stderr, so memoization never engages and
# the pre-push hook perpetually demands a gate re-run whose stamp can never be
# written. scripts/build-sidecar.sh has carried the portable dispatch since it
# first ran on a Mac; gate-stamp.sh now uses the same one.
#
# THE PROPERTY THAT MATTERS: not merely "compute succeeds without sha256sum"
# but "the digest is BYTE-IDENTICAL whichever tool computed it" — stamps are
# compared across runs, so a fallback that produced a different digest would
# invalidate every stamp the moment a host switched tools.
#
# HOW. A throwaway repo (gate-stamp resolves REPO_ROOT from the cwd's
# checkout) with a regular file, a subdirectory file and a symlink (the
# readlink hashing path is a separate call site). S1 computes with the normal
# PATH; S2 recomputes under a farm PATH that has every needed tool EXCEPT
# sha256sum — shasum is the real one where the host ships it, else a shim
# delegating to coreutils (the shim tests the DISPATCH; the digest equality
# still proves the parse shape). MUTATION CONTROL: a mutant with the dispatch
# reverted to bare sha256sum must fail S2's farm run — cmp-verified to differ,
# exactly the sha256sum-less scenario goes red, the full-PATH scenario stays
# green.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$ROOT/scripts/gate-stamp.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gate-stamp-portable.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # <name> <rc>
    if [ "$2" = "0" ]; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi
}

[ -f "$STAMP" ] || { echo "FAIL: no gate-stamp.sh at $STAMP"; exit 1; }
bash -n "$STAMP"; check "gate-stamp-parses" "$?"
grep -q 'GATE_STAMP_SHA256=(shasum -a 256)' "$STAMP"
check "portable-dispatch-present" "$?"

# ── Throwaway repo with all three entry kinds gate-stamp hashes ──────────────
REPO="$WORK/repo"
mkdir -p "$REPO/sub"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email fixture@example.invalid
git -C "$REPO" config user.name Fixture
echo alpha > "$REPO/a.txt"
echo beta > "$REPO/sub/b.txt"
ln -s a.txt "$REPO/link"
git -C "$REPO" add -A
git -C "$REPO" commit -qm seed

# ── S1: baseline digest with the normal PATH ─────────────────────────────────
D1="$(cd "$REPO" && bash "$STAMP" compute 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$D1" | grep -qE '^[0-9a-f]{64}$'
check "S1-compute-succeeds-on-full-path" "$?"

# ── Farm PATH: everything gate-stamp needs, minus sha256sum ──────────────────
FARM="$WORK/farm"
mkdir -p "$FARM"
for t in bash sh git sort cut xargs readlink grep sed awk mktemp rm cat mv \
         dirname basename date head tail wc tr find ls env; do
    p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$FARM/$t"
done
if command -v shasum >/dev/null 2>&1; then
    ln -s "$(command -v shasum)" "$FARM/shasum"
else
    # A Linux host without perl's shasum still exercises the dispatch: the
    # shim delegates to coreutils, which prints the same "<hex>  <name>"
    # shape, so the parse and the digest-equality property are both real.
    REAL_SHA256="$(command -v sha256sum)" || { echo "FAIL: host has neither shasum nor sha256sum"; exit 1; }
    cat > "$FARM/shasum" <<SHIM
#!/bin/sh
# fixture shim: emulate 'shasum -a 256' via coreutils sha256sum
if [ "\${1:-}" = "-a" ] && [ "\${2:-}" = "256" ]; then shift 2; fi
exec "$REAL_SHA256" "\$@"
SHIM
    chmod +x "$FARM/shasum"
fi
if PATH="$FARM" "$FARM/bash" -c 'command -v sha256sum' >/dev/null 2>&1; then
    echo "FAIL  farm-hides-sha256sum: sha256sum still resolvable — S2 proves nothing"
    fail=1
else
    echo "PASS  farm-hides-sha256sum"
fi

# ── S2: same digest without sha256sum on PATH ────────────────────────────────
D2="$(cd "$REPO" && PATH="$FARM" "$FARM/bash" "$STAMP" compute 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ]; check "S2-compute-succeeds-without-sha256sum" "$?"
[ -n "$D1" ] && [ "$D1" = "$D2" ]
check "S2-digest-byte-identical-across-tools" "$?"

# ── MUTATION CONTROL: revert the dispatch, the farm run must fail ────────────
MUTANT="$WORK/gate-stamp-mutant.sh"
sed 's/"${GATE_STAMP_SHA256\[@\]}"/sha256sum/g' "$STAMP" > "$MUTANT"
if cmp -s "$STAMP" "$MUTANT"; then
    echo "FAIL  mutation-applied: sed changed nothing — the control proves nothing"
    fail=1
else
    echo "PASS  mutation-applied"
fi
out="$(cd "$REPO" && PATH="$FARM" "$FARM/bash" "$MUTANT" compute 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] || [ "$out" != "$D1" ]; then
    echo "PASS  mutation-control-bare-sha256sum-fails-without-it"
else
    echo "FAIL  mutation-control-bare-sha256sum-fails-without-it: mutant produced the baseline digest"
    fail=1
fi
out="$(cd "$REPO" && bash "$MUTANT" compute 2>/dev/null)"
rc=$?
# NEGATIVE CONTROL for the mutant arm: on a full PATH the mutant still works —
# proving S2's red came from the missing tool, not from a broken mutant.
if [ "$rc" -eq 0 ] && [ "$out" = "$D1" ]; then
    echo "PASS  mutation-control-full-path-unchanged"
elif command -v sha256sum >/dev/null 2>&1; then
    echo "FAIL  mutation-control-full-path-unchanged: mutant broke on a full PATH"
    fail=1
else
    # A host with no sha256sum at all (pre-13 mac) cannot run the mutant
    # anywhere — the negative control is vacuous there, and says so.
    echo "PASS  mutation-control-full-path-unchanged (skipped: host has no sha256sum)"
fi

if [ "$fail" -eq 0 ]; then
    echo "ok:gate-stamp-portable-digest-fixture:9"
    exit 0
fi
echo "FAIL: gate-stamp-portable-digest fixture had failures"
exit 1
