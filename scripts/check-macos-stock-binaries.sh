#!/usr/bin/env bash
# @trace spec:macos-native-tray, order:1420-umka, order:980-xcaf
#
# check-macos-stock-binaries.sh — the macOS install and provision path runs
# only STOCK macOS binaries, named so a user's PATH cannot change which one.
#
# WHY: QEMU left the provision path in cadbd0e57 and the promise since is "a
# clean Mac needs nothing installed". Nothing guarded it outside vz.rs, and a
# regression is invisible where it is written: a developer Mac has Homebrew on
# its shell PATH, so a bare `Command::new("qemu-img")` or a bare stock name
# shadowed by a Homebrew build works there and fails on the user's clean Mac
# (whose GUI launch gets PATH=/usr/bin:/bin:/usr/sbin:/sbin, 980-xcaf). The
# 2026-09-27 clean-MacBook first-provision failure is why this exists.
#
# WHAT IT CHECKS
#   Rust, over the macOS tray crate and the vm-layer's macOS provisioning
#   sources: every string-literal program given to Command::new(...) or to the
#   tray's spawn_bounded(...) helper must be an absolute path under a stock
#   root (/usr/bin/, /bin/, /usr/sbin/, /sbin/, /System/). A program held in a
#   variable is not a literal and is not judged here.
#   Shell, scripts/install-macos.sh: `export PATH=` naming only stock roots
#   must be the first statement after `set -euo pipefail`, so every later
#   command resolves from stock macOS whatever PATH `curl | bash` inherited.
#
#   check-macos-stock-binaries.sh [--root DIR]
#     ok:macos-stock-binaries:<n> spawn literal(s) checked, installer PATH pinned
#     violation:macos-stock-binaries:<k>     (each offender listed above it)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "${1:-}" = "--root" ]; then
    [ -n "${2:-}" ] || { echo "usage: check-macos-stock-binaries.sh [--root DIR]" >&2; exit 2; }
    ROOT="$2"
fi
cd "$ROOT" || { echo "violation:macos-stock-binaries:no-root"; exit 2; }

bad=0
checked=0

rust_files="$(
    { find crates/tillandsias-macos-tray/src -name '*.rs' 2>/dev/null
      for f in crates/tillandsias-vm-layer/src/vz.rs crates/tillandsias-vm-layer/src/materialize/macos.rs; do
          [ -f "$f" ] && printf '%s\n' "$f"
      done; } | sort
)"
if [ -z "$rust_files" ]; then
    echo "violation:macos-stock-binaries:no-sources-found-under:$ROOT"
    exit 1
fi

# One awk pass per file: print "<line>\t<program>" for every literal spawn.
spawns="$(
    for f in $rust_files; do
        awk -v f="$f" '{
            line = $0
            while (match(line, /(Command::new|spawn_bounded)\("[^"]*"/)) {
                lit = substr(line, RSTART, RLENGTH)
                sub(/^[^"]*"/, "", lit); sub(/"$/, "", lit)
                printf "%s:%d\t%s\n", f, NR, lit
                line = substr(line, RSTART + RLENGTH)
            }
        }' "$f"
    done
)"
while IFS="$(printf '\t')" read -r where prog; do
    [ -n "$where" ] || continue
    checked=$((checked + 1))
    case "$prog" in
        (/usr/bin/?* | /bin/?* | /usr/sbin/?* | /sbin/?* | /System/?*) ;;
        (*)
            echo "  $where: spawns \"$prog\" — not an absolute stock-macOS path (/usr/bin, /bin, /usr/sbin, /sbin, /System)"
            bad=$((bad + 1)) ;;
    esac
done <<EOF
$spawns
EOF

inst="scripts/install-macos.sh"
if [ ! -f "$inst" ]; then
    echo "  $inst: missing"
    bad=$((bad + 1))
else
    # The first non-blank, non-comment line after `set -euo pipefail`.
    first="$(awk '
        seen_set && $0 !~ /^[[:space:]]*(#|$)/ { print; exit }
        /^set -euo pipefail[[:space:]]*$/ { seen_set = 1 }
    ' "$inst")"
    case "$first" in
        ("export PATH=/usr/bin:/bin:/usr/sbin:/sbin") ;;
        (*)
            echo "  $inst: the first statement after 'set -euo pipefail' must be 'export PATH=/usr/bin:/bin:/usr/sbin:/sbin' (found: '${first}')"
            bad=$((bad + 1)) ;;
    esac
fi

if [ "$bad" -gt 0 ]; then
    echo "violation:macos-stock-binaries:$bad"
    exit 1
fi
echo "ok:macos-stock-binaries:$checked spawn literal(s) checked, installer PATH pinned"
exit 0
