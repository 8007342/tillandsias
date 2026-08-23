#!/usr/bin/env bash
# @trace order:317, spec:default-image
#
# Fixture for the brew shim's owned aarch64 Tier-2 policy line (order 317,
# scope item 3). Homebrew on aarch64 Linux — every macOS-hosted guest — has
# no supported bottles, so on-demand installs can degrade to slow source
# builds; the shim now states that policy in ONE line before attempting the
# install, replacing Homebrew's "unsupported, do not report issues" wall.
#
# Behavioral, per 634-39ik: the shim is RUN under a shimmed uname with a
# fixture allowlist and a stub brew prefix, in three scenarios — the warning
# must appear on the aarch64 install path, must NOT appear on x86_64 (the
# per-arch negative control), and must NOT appear on the already-installed
# exec path even on aarch64 (the install-scope negative control). A
# cmp-verified mutant with the arch test neutered turns exactly the aarch64
# scenario red.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$ROOT/images/default/brew-shim-exec.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/brew-tier2.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # <name> <rc>
    if [ "$2" = "0" ]; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi
}

[ -f "$SHIM" ] || { echo "FAIL: no shim at $SHIM"; exit 1; }
bash -n "$SHIM"; check "shim-parses" "$?"

# ── Fixture world ────────────────────────────────────────────────────────────
SHIMS="$WORK/shims"
PREFIX="$WORK/prefix"
mkdir -p "$SHIMS" "$PREFIX/bin"
printf '#!/bin/sh\ncase "${1:-}" in -s) echo "${UNAME_S:-Linux}";; -m) echo "${UNAME_M:-x86_64}";; *) echo "${UNAME_S:-Linux}";; esac\n' > "$SHIMS/uname"
chmod +x "$SHIMS/uname"
# A brew stub that "succeeds" without a network; the shim then discovers the
# tool was not provided and exits 127 — far enough to prove warning placement.
printf '#!/bin/sh\nexit 0\n' > "$PREFIX/bin/brew"
chmod +x "$PREFIX/bin/brew"
printf 'mytool mytool\n' > "$WORK/allowlist.txt"

run_shim() { # <uname_m> -> stderr; rc in $?
    UNAME_S=Linux UNAME_M="$1" PATH="$SHIMS:$PATH" \
    TILLANDSIAS_BREW_PREFIX="$PREFIX" \
    TILLANDSIAS_BREW_ALLOWLIST="$WORK/allowlist.txt" \
    TILLANDSIAS_PROJECT_CACHE="$WORK/cache" \
        bash "${2:-$SHIM}" mytool mytool 2>&1 >/dev/null
}

# ── aarch64 install path: the owned one-line policy statement appears ────────
out="$(run_shim aarch64)"
printf '%s' "$out" | grep -q 'Tier 2 (no bottles)'
check "aarch64-install-path-states-the-policy" "$?"
printf '%s' "$out" | grep -q 'order 317'
check "policy-line-cites-its-order" "$?"

# ── x86_64 install path (NEGATIVE CONTROL): no Tier-2 line ───────────────────
out="$(run_shim x86_64)"
! printf '%s' "$out" | grep -q 'Tier 2'
check "x86-64-install-path-stays-silent" "$?"

# ── aarch64 exec path (NEGATIVE CONTROL): already-installed tool, no line ────
printf '#!/bin/sh\necho ran\n' > "$PREFIX/bin/mytool"
chmod +x "$PREFIX/bin/mytool"
out="$(run_shim aarch64)"
! printf '%s' "$out" | grep -q 'Tier 2'
check "aarch64-exec-path-stays-silent" "$?"
rm -f "$PREFIX/bin/mytool"

# ── MUTATION CONTROL: neuter the arch test, the aarch64 scenario goes red ────
MUTANT="$WORK/shim-mutant.sh"
sed 's/= "aarch64" \]/= "NEVERMATCH" ]/' "$SHIM" > "$MUTANT"
if cmp -s "$SHIM" "$MUTANT"; then
    echo "FAIL  mutation-applied: sed changed nothing — the control proves nothing"
    fail=1
else
    echo "PASS  mutation-applied"
fi
out="$(run_shim aarch64 "$MUTANT")"
! printf '%s' "$out" | grep -q 'Tier 2'
check "mutation-control-neutered-arch-test-loses-the-line" "$?"
out="$(run_shim x86_64 "$MUTANT")"
! printf '%s' "$out" | grep -q 'Tier 2'
check "mutation-control-x86-64-unchanged" "$?"

if [ "$fail" -eq 0 ]; then
    echo "ok:brew-shim-tier2-warning-fixture:8"
    exit 0
fi
echo "FAIL: brew-shim-tier2-warning fixture had failures"
exit 1
