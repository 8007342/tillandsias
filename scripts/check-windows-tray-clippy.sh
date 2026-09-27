#!/usr/bin/env bash
# @trace order:1434-vm7g, spec:windows-native-tray
#
# check-windows-tray-clippy.sh — native clippy -D warnings on the Windows tray,
# run where a Windows host actually runs it.
#
# THE GAP. tillandsias-windows-tray is cfg(windows). On a Linux host its
# Windows-only modules compile as src/stubs/ substitutes (716-f5kc), and on a
# Windows host ./build.sh re-execs inside the tillandsias-build WSL2 distro
# (scripts/with-wsl2-builder.sh), which is Linux too. So no gate ever linted
# the real sources: on 2026-09-27 native clippy 0.1.98 -D warnings found three
# errors plus a fourth behind them (1434-vm7g), and none had been seen.
#
# WHY THE PRE-PUSH HOOK AND NOT A build.sh STEP. A build.sh step would run in
# the WSL builder on every Windows host and skip, forever: a gate that can
# never fire. git runs the pre-push hook natively in Git Bash, so a check
# called from there reaches the real toolchain.
#
# SCOPE. Only when the change touches the crate (against the base, plus
# untracked files there): a clippy build costs minutes, and a push that does
# not touch the crate cannot add a warning to it. --all forces a run.
#
# Seams (fixture use): TILLANDSIAS_WINDOWS_CLIPPY_UNAME (stands in for
# `uname -s`), TILLANDSIAS_WINDOWS_CLIPPY_MANIFEST (a Cargo.toml to lint
# instead of the tray crate; its directory is the scope prefix),
# TILLANDSIAS_WINDOWS_CLIPPY_BASE (default origin/linux-next).
#
# Verdicts (last stdout line):
#   ok:windows-tray-clippy:clean
#   skip:windows-tray-clippy:not-windows:<uname>
#   skip:windows-tray-clippy:crate-untouched
#   skip:windows-tray-clippy:base-ref-unavailable:<ref>
#   could-not-run:windows-tray-clippy:no-cargo            (exit 3)
#   refused:windows-tray-clippy:<n>-errors                (exit 1)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3

uname_s="${TILLANDSIAS_WINDOWS_CLIPPY_UNAME:-$(uname -s 2>/dev/null)}"
case "$uname_s" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) echo "skip:windows-tray-clippy:not-windows:${uname_s:-unknown}"; exit 0 ;;
esac

manifest="${TILLANDSIAS_WINDOWS_CLIPPY_MANIFEST:-crates/tillandsias-windows-tray/Cargo.toml}"
prefix="$(dirname "$manifest")/"

if [ "${1:-}" != "--all" ]; then
    base="${TILLANDSIAS_WINDOWS_CLIPPY_BASE:-origin/linux-next}"
    if ! git rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
        echo "skip:windows-tray-clippy:base-ref-unavailable:$base"
        exit 0
    fi
    changed="$({ git diff --name-only "$base" -- "$prefix" 2>/dev/null
                 git ls-files --others --exclude-standard -- "$prefix" 2>/dev/null; } | LC_ALL=C sort -u)"
    if [ -z "$changed" ]; then
        echo "skip:windows-tray-clippy:crate-untouched"
        exit 0
    fi
fi

command -v cargo >/dev/null 2>&1 || { echo "could-not-run:windows-tray-clippy:no-cargo"; exit 3; }

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
cargo clippy --manifest-path "$manifest" --all-targets -- -D warnings > "$log" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "ok:windows-tray-clippy:clean"
    exit 0
fi
# Count DISTINCT findings: --all-targets lints the same line once per target
# (bin, bin test), and cargo adds a "could not compile" line per target, so a
# raw count of error lines says 3 for one warning.
findings="$(awk '/^error: could not compile/ {next}
                 /^error: / {msg=$0; next}
                 msg != "" && /^ *--> / {sub(/^ *--> /, ""); print msg " @ " $0; msg=""}' "$log" | LC_ALL=C sort -u)"
n="$(printf '%s\n' "$findings" | grep -c .)" || true
printf '%s\n' "$findings" | head -20 | sed 's/^/  /' >&2
echo "  remedy: fix each site above; 'cargo clippy -p tillandsias-windows-tray --all-targets -- -D warnings' reproduces it natively" >&2
echo "refused:windows-tray-clippy:${n}-errors"
exit 1
