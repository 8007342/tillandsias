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

# ORDER 1444-bzpu: WIDENED from the tray to every crate with cfg(windows)
# code. Measured 2026-09-27: native clippy refused tillandsias-podman on 12
# sites and, behind them, tillandsias-headless on 7 — the same class as the
# tray, in crates no gate compiled for Windows. The candidates are the crates
# under $crates_root whose src/ carries a cfg(windows)/cfg(target_os =
# "windows") attribute; comment lines are stripped before matching, so a crate
# that merely DISCUSSES the attribute is not pulled in (a false inclusion would
# only cost a lint, but a scan that reads comments measures the comments).
# TILLANDSIAS_WINDOWS_CLIPPY_MANIFEST keeps its meaning: exactly that one crate.
crates_root="${TILLANDSIAS_WINDOWS_CLIPPY_CRATES_DIR:-crates}"
_has_windows_cfg() { # <crate dir>
    [ -d "$1/src" ] || return 1
    local hits
    hits="$(find "$1/src" -name '*.rs' -exec sed -e 's#//.*$##' {} + 2>/dev/null \
            | grep -cE 'cfg\((target_os *= *"windows"|windows)')" || true
    [ "${hits:-0}" -gt 0 ]
}
if [ -n "${TILLANDSIAS_WINDOWS_CLIPPY_MANIFEST:-}" ]; then
    candidates="$(dirname "$TILLANDSIAS_WINDOWS_CLIPPY_MANIFEST")"
else
    candidates=""
    for d in "$crates_root"/*/; do
        d="${d%/}"
        [ -f "$d/Cargo.toml" ] || continue
        _has_windows_cfg "$d" && candidates="$candidates$d
"
    done
fi

targets=""
if [ "${1:-}" = "--all" ]; then
    targets="$candidates"
else
    base="${TILLANDSIAS_WINDOWS_CLIPPY_BASE:-origin/linux-next}"
    if ! git rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
        echo "skip:windows-tray-clippy:base-ref-unavailable:$base"
        exit 0
    fi
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        changed="$({ git diff --name-only "$base" -- "$d/" 2>/dev/null
                     git ls-files --others --exclude-standard -- "$d/" 2>/dev/null; } | head -1)"
        [ -n "$changed" ] && targets="$targets$d
"
    done <<EOF
$candidates
EOF
fi
if [ -z "$(printf '%s' "$targets" | tr -d '[:space:]')" ]; then
    echo "skip:windows-tray-clippy:crate-untouched"
    exit 0
fi

command -v cargo >/dev/null 2>&1 || { echo "could-not-run:windows-tray-clippy:no-cargo"; exit 3; }

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
: > "$log"
failed=""
linted=0
while IFS= read -r d; do
    [ -n "$d" ] || continue
    linted=$((linted + 1))
    if ! cargo clippy --manifest-path "$d/Cargo.toml" --all-targets -- -D warnings >> "$log" 2>&1; then
        failed="$failed ${d##*/}"
    fi
done <<EOF
$targets
EOF
echo "  linted $linted crate(s) with cfg(windows) code natively" >&2
if [ -z "$failed" ]; then
    echo "ok:windows-tray-clippy:clean"
    exit 0
fi
# Count DISTINCT findings: --all-targets lints the same line once per target
# (bin, bin test), and cargo adds a "could not compile" line per target, so a
# raw count of error lines says 3 for one warning. A dependency's finding seen
# through two touched crates is also one finding.
findings="$(awk '/^error: could not compile/ {next}
                 /^error: / {msg=$0; next}
                 msg != "" && /^ *--> / {sub(/^ *--> /, ""); print msg " @ " $0; msg=""}' "$log" | LC_ALL=C sort -u)"
n="$(printf '%s
' "$findings" | grep -c .)" || true
printf '%s
' "$findings" | head -20 | sed 's/^/  /' >&2
echo "  refused in:$failed" >&2
echo "  remedy: fix each site above; 'cargo clippy -p <crate> --all-targets -- -D warnings' reproduces it natively" >&2
echo "refused:windows-tray-clippy:${n}-errors"
exit 1
