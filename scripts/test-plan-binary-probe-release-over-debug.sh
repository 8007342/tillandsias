#!/usr/bin/env bash
# @trace order:1508-7s4w
#
# On MSYS (Git Bash) an extensionless candidate whose .exe sibling exists IS
# that .exe (exe magic). resolve_plan_binary used to try
# ./target/debug/tillandsias-plan before ./target/release/tillandsias-plan.exe,
# so with an unrunnable file at the extensionless release path it answered the
# DEBUG build ahead of a fresh release one (measured on yolanda 2026-09-29).
#
#   MSYS arm   a scratch target/ with a runnable release .exe NEWER than a
#              runnable debug .exe, plus an unrunnable ELF header planted at
#              target/release/tillandsias-plan: the probe answers the release
#              .exe (pre-fix: ./target/debug/tillandsias-plan)
#   LINUX arm  NEGATIVE CONTROL: with runnable extensionless release and debug
#              stubs, the probe still answers the extensionless release path,
#              so the order there is unchanged
#
# The extensionless file is created BEFORE its .exe sibling exists: on MSYS a
# write to `foo` when `foo.exe` exists lands IN foo.exe.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/scripts/plan-binary-probe.sh"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/probe-release-over-debug.XXXXXX")"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/target/release" "$W/target/debug"

answer() { (cd "$W" && unset CARGO_TARGET_DIR TILLANDSIAS_PLAN_BIN && . "$PROBE" && resolve_plan_binary) 2>/dev/null; }

case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        real="$(cd "$ROOT" && unset TILLANDSIAS_PLAN_BIN && . "$PROBE" && resolve_plan_binary 2>/dev/null)"
        case "$real" in ./*) real="$ROOT/${real#./}" ;; esac
        [ -f "$real" ] || [ -f "$real.exe" ] || {
            echo "skip:plan-binary-probe-release-over-debug:no-plan-binary (build one: cargo build --release -p tillandsias-plan)"; exit 0; }
        [ -f "$real.exe" ] && real="$real.exe"
        # 1. the unrunnable extensionless file FIRST, while no .exe sibling exists
        printf '\177ELF\002\001\001\000' > "$W/target/release/tillandsias-plan"
        # 2. then the runnable binaries; release made newer than debug
        cp "$real" "$W/target/debug/tillandsias-plan.exe"
        cp "$real" "$W/target/release/tillandsias-plan.exe"
        touch -d '2020-01-01' "$W/target/debug/tillandsias-plan.exe"
        sz="$(wc -c < "$W/target/release/tillandsias-plan.exe" | tr -d ' ')"
        if [ "${sz:-0}" -lt 1000 ]; then
            bad "setup: the release .exe is ${sz} bytes, so the plant landed in it"
        else
            got="$(answer)"
            case "$got" in
                ./target/release/tillandsias-plan.exe)
                    ok "MSYS: with an unrunnable ELF at the release path, the probe answers the release .exe ($got)" ;;
                *) bad "MSYS: the probe answered [$got], want ./target/release/tillandsias-plan.exe (pre-fix: ./target/debug/tillandsias-plan)" ;;
            esac
        fi
        echo "skip: LINUX arm needs a Linux kernel (negative control runs there)"
        ;;
    *)
        for d in release debug; do
            printf '#!/bin/sh\n[ "$1" = capabilities ] && exit 0\nexit 0\n' > "$W/target/$d/tillandsias-plan"
            chmod +x "$W/target/$d/tillandsias-plan"
        done
        got="$(answer)"
        case "$got" in
            ./target/release/tillandsias-plan)
                ok "LINUX negative control: the order is unchanged, release extensionless answers ($got)" ;;
            *) bad "LINUX negative control: the probe answered [$got], want ./target/release/tillandsias-plan" ;;
        esac
        echo "skip: MSYS arm needs an MSYS kernel (it runs on Windows Git Bash)"
        ;;
esac

total=$((pass+fail))
if [ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]; then echo "ok:plan-binary-probe-release-over-debug:$pass/$total"; exit 0; fi
echo "violation:plan-binary-probe-release-over-debug:$pass/$total"; exit 1
