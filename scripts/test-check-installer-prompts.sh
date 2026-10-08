#!/usr/bin/env bash
# @trace order:1560-g5d9, spec:host-state-lifecycle
#
# test-check-installer-prompts.sh — the end-user installer prompt ratchet.
# Operator ruling 2026-10-08: "we do not ask end users to do power user stuff
# ... No prompts like those, we make all the decisions for them".
#
# Runs the REAL scripts/check-installer-prompts.sh over the real tree and over
# scratch copies of the population (TILLANDSIAS_INSTALLER_PROMPT_ROOT seam):
#   1 the real tree, at the floor                      -> ok
#   2 a `read -p ... [y/N]` added to install.sh        -> refused, naming file:line
#   3 a Read-Host added to install-windows.ps1         -> refused, naming file:line
#   4 a prompt quoted only in a comment                -> ok (comments are stripped)
#   5 one existing prompt removed (below the floor)    -> ok, with the lower-the-floor note
# Each mutant asserts its own edit landed exactly once.
# Pre-fix: FAILS — the guard does not exist.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/check-installer-prompts.sh"
if [ ! -f "$GUARD" ]; then
    echo "fail:installer-prompts-fixture:guard-missing:scripts/check-installer-prompts.sh"
    exit 1
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
POP="scripts/install.sh scripts/install-macos.sh scripts/install-windows.ps1"

scratch() { # scratch <dir>: a copy of the population under <dir>
    mkdir -p "$1/scripts/portability"
    for f in $POP; do cp "$ROOT/$f" "$1/$f"; done
    cp "$ROOT/scripts/portability/installer-prompt-floor.txt" "$1/scripts/portability/"
}
guard() { # guard [root] -> RC, OUT
    if [ -n "${1:-}" ]; then
        OUT="$(cd "$ROOT" && TILLANDSIAS_INSTALLER_PROMPT_ROOT="$1" bash "$GUARD" 2>&1)"; RC=$?
    else
        OUT="$(cd "$ROOT" && bash "$GUARD" 2>&1)"; RC=$?
    fi
}
append_once() { # append_once <file> <line>: append and assert it landed once
    printf '%s\n' "$2" >> "$1"
    [ "$(grep -cxF -- "$2" "$1")" = "1" ]
}

# 1 — the real tree is at the floor.
guard
if [ "$RC" -eq 0 ]; then pass "1 real tree: $OUT"; else bad "1 real tree rc=$RC: $OUT"; fi

# 2 — a new read -p in install.sh.
scratch "$TMP/a"
if append_once "$TMP/a/scripts/install.sh" 'read -r -p "Continue? [y/N] " answer'; then
    guard "$TMP/a"
    case "$RC:$OUT" in
        1:*scripts/install.sh:*) pass "2 a new read -p is refused by file:line" ;;
        *) bad "2 new read -p: rc=$RC out=[$OUT]" ;;
    esac
else bad "2 mutant did not land once"; fi

# 3 — a new Read-Host in install-windows.ps1.
scratch "$TMP/b"
if append_once "$TMP/b/scripts/install-windows.ps1" '$x = Read-Host "Proceed"'; then
    guard "$TMP/b"
    case "$RC:$OUT" in
        1:*scripts/install-windows.ps1:*) pass "3 a new Read-Host is refused by file:line" ;;
        *) bad "3 new Read-Host: rc=$RC out=[$OUT]" ;;
    esac
else bad "3 mutant did not land once"; fi

# 4 — a prompt that is only a comment does not count.
scratch "$TMP/c"
if append_once "$TMP/c/scripts/install.sh" '# never do: read -p "Continue? [y/N] "'; then
    guard "$TMP/c"
    if [ "$RC" -eq 0 ]; then pass "4 a commented prompt does not count"; else bad "4 comment counted: rc=$RC out=[$OUT]"; fi
else bad "4 mutant did not land once"; fi

# 5 — one prompt removed: below the floor passes, and says to lower it.
scratch "$TMP/d"
before="$(grep -c 'Read-Host' "$TMP/d/scripts/install-windows.ps1")"
awk 'done != 1 && /Read-Host/ { done = 1; next } { print }' "$ROOT/scripts/install-windows.ps1" > "$TMP/d/scripts/install-windows.ps1"
after="$(grep -c 'Read-Host' "$TMP/d/scripts/install-windows.ps1")"
if [ "$after" -ne $((before - 1)) ]; then
    bad "5 mutant did not remove exactly one Read-Host ($before -> $after)"
else
    guard "$TMP/d"
    case "$RC:$OUT" in
        0:*lower*floor*) pass "5 below the floor passes and asks for the floor to drop" ;;
        *) bad "5 below floor: rc=$RC out=[$OUT]" ;;
    esac
fi

if [ "$fails" -ne 0 ]; then
    echo "fail:installer-prompts-fixture:$fails"
    exit 1
fi
echo "ok:installer-prompts-fixture:5 arms"
