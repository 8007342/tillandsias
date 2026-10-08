#!/usr/bin/env bash
# @trace order:1561-47a8, order:1561-9f4x, spec:host-state-lifecycle
#
# test-check-installer-end-user-output.sh — the end-user installers print only
# end-user lines (operator ruling 2026-10-08: "we do not need to print any power
# user messages during install, at all ... a pretty installer, rather than an
# informational/debugging installer").
#
# Runs the REAL scripts/check-installer-end-user-output.sh over the real tree
# (so the floors are enforced here) and over scratch copies of the installers
# (TILLANDSIAS_INSTALLER_OUTPUT_ROOT seam):
#   1 the real tree, at the floors                          -> ok
#   2 install-windows.ps1 gains `Say "... --some-flag ..."` -> refused by file:line
#   3 the same line marked `# power-user-only`              -> ok
#   4 the same line inside a PENDING-1560-UAM3 region        -> ok
#   5 install.sh gains a `say "... TILLANDSIAS_X ..."`       -> refused (above its floor)
#   6 the text only in a comment                            -> ok
# Each mutant asserts its own edit landed exactly once.
# Pre-fix (trunk 2026-10-08): FAILS — install-windows.ps1 prints 21 diagnostic
# lines (resolved-channel, --version/--diagnose verification, --init launch).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/check-installer-end-user-output.sh"
[ -f "$GUARD" ] || { echo "fail:installer-end-user-output-fixture:guard-missing"; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
POP="scripts/install-windows.ps1 scripts/install.sh scripts/install-macos.sh"

scratch() {
    mkdir -p "$1/scripts/portability"
    for f in $POP; do cp "$ROOT/$f" "$1/$f"; done
    cp "$ROOT/scripts/portability/installer-end-user-output-floor.txt" "$1/scripts/portability/"
}
guard() {
    if [ -n "${1:-}" ]; then
        OUT="$(cd "$ROOT" && TILLANDSIAS_INSTALLER_OUTPUT_ROOT="$1" bash "$GUARD" 2>&1)"; RC=$?
    else
        OUT="$(cd "$ROOT" && bash "$GUARD" 2>&1)"; RC=$?
    fi
}
append_once() { # append_once <file> <line>...: append the lines, assert the first landed once
    local file="$1"; shift
    printf '%s\n' "$@" >> "$file"
    [ "$(grep -cxF -- "$1" "$file")" = "1" ]
}

# 1 — the real tree.
guard
first_line="${OUT%%$'\n'*}"
if [ "$RC" -eq 0 ]; then pass "1 real tree: $OUT"; else bad "1 real tree rc=$RC: $first_line"; fi

# 2 — a diagnostic line added to the Windows installer.
scratch "$TMP/a"
if append_once "$TMP/a/scripts/install-windows.ps1" 'Say "  run with --some-flag to see more"'; then
    guard "$TMP/a"
    case "$RC:$OUT" in
        1:*scripts/install-windows.ps1:*) pass "2 a flag-naming line is refused by file:line" ;;
        *) bad "2 flag line: rc=$RC out=[$OUT]" ;;
    esac
else bad "2 mutant did not land once"; fi

# 3 — the same line marked power-user-only.
scratch "$TMP/b"
if append_once "$TMP/b/scripts/install-windows.ps1" 'Say "  run with --some-flag to see more"  # power-user-only'; then
    guard "$TMP/b"
    if [ "$RC" -eq 0 ]; then pass "3 a power-user-only line is exempt"; else bad "3 power-user-only: rc=$RC out=[$OUT]"; fi
else bad "3 mutant did not land once"; fi

# 4 — the same line inside the pending-prompt region.
scratch "$TMP/c"
if append_once "$TMP/c/scripts/install-windows.ps1" '# BEGIN-PENDING-1560-UAM3' 'Say "  run with --some-flag to see more"' '# END-PENDING-1560-UAM3'; then
    guard "$TMP/c"
    if [ "$RC" -eq 0 ]; then pass "4 a line in the pending-prompt region is exempt"; else bad "4 pending region: rc=$RC out=[$OUT]"; fi
else bad "4 mutant did not land once"; fi

# 5 — install.sh above its floor.
scratch "$TMP/d"
if append_once "$TMP/d/scripts/install.sh" 'say "  set TILLANDSIAS_X=1 for more"'; then
    guard "$TMP/d"
    case "$RC:$OUT" in
        1:*scripts/install.sh:*) pass "5 install.sh above its floor is refused" ;;
        *) bad "5 install.sh: rc=$RC out=[$OUT]" ;;
    esac
else bad "5 mutant did not land once"; fi

# 6 — the text only in a comment.
scratch "$TMP/e"
if append_once "$TMP/e/scripts/install-windows.ps1" '# Say "  run with --some-flag to see more"'; then
    guard "$TMP/e"
    if [ "$RC" -eq 0 ]; then pass "6 a commented line does not count"; else bad "6 comment counted: rc=$RC out=[$OUT]"; fi
else bad "6 mutant did not land once"; fi

if [ "$fails" -ne 0 ]; then
    echo "fail:installer-end-user-output-fixture:$fails"
    exit 1
fi
echo "ok:installer-end-user-output-fixture:6 arms"
