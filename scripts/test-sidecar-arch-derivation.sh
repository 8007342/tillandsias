#!/usr/bin/env bash
# @trace order:723-ji4v, spec:ci-release
#
# Fixture for the router sidecar's per-arch build and guest-side guard
# (order 723-ji4v). What was broken, measured on the first Apple-Silicon
# host 2026-08-23: build-sidecar.sh pinned TARGET=x86_64-unknown-linux-musl
# unconditionally, file(1) confirmed an x86-64 ELF staged for an aarch64
# guest, and images/router/entrypoint.sh respawned the ENOEXEC binary once a
# second while Caddy 502'd — a wrong-arch artifact whose failure mode was
# silent at every layer that could have caught it.
#
# Three surfaces, each behavioral:
#   1. TARGET derivation (build-sidecar.sh --print-target seam) under a
#      shimmed uname: x86_64 -> x86_64 triple, arm64 -> aarch64 triple,
#      unknown machine -> loud rc 2, env override wins.
#   2. The entrypoint's static ELF e_machine guard, extracted by its begin/
#      end markers and driven with CRAFTED 20-byte headers — hermetic, no
#      real binary needed: wrong arch refuses (exit 1), right arch passes,
#      unknown machine degrades open.
#   3. Mutation controls, cmp-verified: a derivation with the arm64 arm
#      neutered goes red on exactly the arm64 scenario; a guard with the
#      comparison neutered goes red on exactly the wrong-arch scenario.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/scripts/build-sidecar.sh"
ENTRY="$ROOT/images/router/entrypoint.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sidecar-arch.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # <name> <rc>
    if [ "$2" = "0" ]; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi
}

bash -n "$BUILD"; check "build-sidecar-parses" "$?"
bash -n "$ENTRY"; check "entrypoint-parses" "$?"

# ── Shimmed uname ────────────────────────────────────────────────────────────
SHIMS="$WORK/shims"
mkdir -p "$SHIMS"
printf '#!/bin/sh\ncase "${1:-}" in -m) echo "${UNAME_M:-x86_64}";; *) echo "${UNAME_S:-Linux}";; esac\n' > "$SHIMS/uname"
chmod +x "$SHIMS/uname"
BASH_BIN="${BASH:-$(command -v bash)}"

derive() { # <uname_m> [script] -> stdout; rc in $?
    UNAME_M="$1" PATH="$SHIMS:$PATH" "$BASH_BIN" "${2:-$BUILD}" --print-target 2>/dev/null
}

# ── 1. derivation ────────────────────────────────────────────────────────────
[ "$(derive x86_64)" = "x86_64-unknown-linux-musl" ]
check "x86-64-machine-derives-x86-64-musl" "$?"
[ "$(derive arm64)" = "aarch64-unknown-linux-musl" ]
check "arm64-machine-derives-aarch64-musl" "$?"
[ "$(derive aarch64)" = "aarch64-unknown-linux-musl" ]
check "aarch64-machine-derives-aarch64-musl" "$?"
derive riscv64 >/dev/null 2>&1
[ "$?" -eq 2 ]
check "unknown-machine-fails-loud-rc2" "$?"
out="$(UNAME_M=riscv64 TILLANDSIAS_SIDECAR_TARGET=powerpc64le-unknown-linux-musl PATH="$SHIMS:$PATH" "$BASH_BIN" "$BUILD" --print-target 2>/dev/null)"
[ "$out" = "powerpc64le-unknown-linux-musl" ]
check "explicit-override-wins" "$?"

# ── 2. entrypoint guard, extracted by markers, crafted ELF headers ───────────
awk '/723-ji4v sidecar-executability guard begin/,/723-ji4v sidecar-executability guard end/' \
    "$ENTRY" > "$WORK/guard.sh"
grep -q 'e_machine' "$WORK/guard.sh"
check "guard-extracted" "$?"

mk_elf() { # <path> <e_machine decimal (fits one byte for 62; 183 fits too)>
    # 20 bytes: ELF magic + padding; bytes 18-19 = e_machine little-endian.
    printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000' > "$1"
    printf "$(printf '\\%03o\\000' "$2")" >> "$1"
}

run_guard() { # <uname_m> <e_machine> [guard] -> rc
    local bin="$WORK/bin-$2"
    mk_elf "$bin" "$2"
    UNAME_M="$1" PATH="$SHIMS:$PATH" SIDECAR_TEST_BIN="$bin" "$BASH_BIN" -c '
        set -eu
        # The guard names its binary absolutely; point it at the fixture.
        sed "s|/usr/local/bin/tillandsias-router-sidecar|$SIDECAR_TEST_BIN|" "$1" > "$2"
        . "$2"
        echo GUARD_PASSED
    ' _ "${3:-$WORK/guard.sh}" "$WORK/guard-run.sh" 2>/dev/null | grep -q GUARD_PASSED
}

run_guard aarch64 62; rc=$?
[ "$rc" -ne 0 ]
check "wrong-arch-sidecar-refused-on-aarch64" "$?"
run_guard aarch64 183
check "right-arch-sidecar-passes-on-aarch64" "$?"
run_guard x86_64 62
check "x86-64-sidecar-passes-on-x86-64" "$?"
run_guard riscv64 62
check "unknown-guest-machine-degrades-open" "$?"

# ── 3. mutation controls ─────────────────────────────────────────────────────
sed 's/arm64|aarch64)/NEVER-A|NEVER-B)/' "$BUILD" > "$WORK/build-mutant.sh"
cmp -s "$BUILD" "$WORK/build-mutant.sh" && { echo "FAIL  build-mutation-applied"; fail=1; } || echo "PASS  build-mutation-applied"
derive arm64 "$WORK/build-mutant.sh" >/dev/null 2>&1
[ "$?" -eq 2 ]
check "mutation-control-neutered-derivation-fails-arm64" "$?"
[ "$(derive x86_64 "$WORK/build-mutant.sh")" = "x86_64-unknown-linux-musl" ]
check "mutation-control-x86-64-derivation-unchanged" "$?"

sed 's/"$e_machine" != "$want_machine"/"NEVER" = "MATCHES"/' "$WORK/guard.sh" > "$WORK/guard-mutant.sh"
cmp -s "$WORK/guard.sh" "$WORK/guard-mutant.sh" && { echo "FAIL  guard-mutation-applied"; fail=1; } || echo "PASS  guard-mutation-applied"
run_guard aarch64 62 "$WORK/guard-mutant.sh"
check "mutation-control-neutered-guard-passes-the-breach" "$?"

if [ "$fail" -eq 0 ]; then
    echo "ok:sidecar-arch-derivation-fixture:17"
    exit 0
fi
echo "FAIL: sidecar-arch-derivation fixture had failures"
exit 1
