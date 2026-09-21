#!/usr/bin/env bash
# @trace spec:ci-release
# @trace order:1323-5taw
#
# Pin 1323-5taw: install-windows.ps1 decides whether the tray supports
# --reset-state by ATTEMPTING it under the non-destructive guard and reading
# the outcome, never by grepping --help.
#
# PRE-FIX RESULT, and it has a real specimen. The probe used to be:
#     $ResetHelp = & cmd.exe /c "`"$InstalledExe`" --help 2>&1"
#     $HasResetState = ($ResetHelp -join "`n") -match '--reset-state'
# which is defeated by exactly the defect it was written to survive -- a
# binary whose --help MENTIONS a flag its parser REJECTS. v56.9.20.1's
# published Linux headless is that binary: its allow-list at
# crates/tillandsias-headless/src/main.rs:612-651 carries no --reset-state
# entry, and pirria's curl-install died with `Unsupported option:
# --reset-state`, install_exit=2. Against it the old probe answered YES and
# the installer then Died on the exit 2 the probe existed to avoid.
#
# THE BEHAVIOURAL ARM BELOW BUILDS THAT LIAR. A stub that prints the flag in
# --help and refuses it with exit 2 is the whole defect in eight lines, and it
# is what separates "asks what the binary claims" from "asks what it does".
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

SRC="${TILLANDSIAS_INSTALLER_SRC:-scripts/install-windows.ps1}"
[ -f "$SRC" ] || { echo "blocked:installer-probe:no-installer:$SRC"; exit 1; }

fail=0
_ok()  { echo "ok: $1"; }
_bad() { echo "FAIL: $1"; fail=1; }

# Comments are stripped: this file and the installer both QUOTE the forbidden
# idiom while explaining it, and a scan that reads comments refuses the very
# tree that fixed the defect.
CODE="$(mktemp)"; trap 'rm -f "$CODE"' EXIT
sed 's/#.*//' "$SRC" > "$CODE"

# ARM 1 -- THE DEFECT. No --help output may decide the capability.
if grep -qE '\$(ResetHelp|[A-Za-z]*Help)[^=]*=.*--help' "$CODE"; then
    _bad "the installer still reads --help to decide capability"
else
    _ok "no --help capture feeds the capability decision"
fi
if grep -qE "match +'--reset-state'|-match .*--reset-state" "$CODE"; then
    _bad "the capability decision still pattern-matches for the flag name"
else
    _ok "the decision is not a pattern match on the flag name"
fi

# ARM 2 -- THE REPLACEMENT. The attempt must be present, guarded, and the
# decision must be taken from its EXIT CODE.
# CARDINALITY, not presence. The first version of this arm asked only whether
# the guard string and `ProbeExit` appeared ANYWHERE, and it stayed GREEN
# against a reconstructed pre-fix installer -- the reporting lines that
# mention $ProbeExit outlive the probe they report on. Presence of a name is
# not presence of the call. Require exactly one line that both sets the guard
# and passes the flag: that line IS the attempt.
_attempts=$(grep -c 'TILLANDSIAS_DESTRUCTIVE_RESET_OK=0.*--reset-state' "$CODE")
if [ "$_attempts" -eq 1 ]; then
    _ok "the probe attempts the flag under the non-destructive guard (exactly 1 such call)"
else
    _bad "expected exactly 1 guarded --reset-state attempt, found $_attempts; the probe must run the flag, not read about it"
fi
if grep -qE '\$HasResetState *= *\(\$ProbeExit -eq 0\)' "$CODE"; then
    _ok "the capability decision is taken from the attempt's exit code"
else
    _bad "the decision is not taken from the attempt's exit code"
fi

# ARM 3 -- BEHAVIOURAL, msys only: the decision RULE against a LIAR.
# Three stubs: one that supports the flag, one that lies in --help and
# rejects it (the v56.9.20.1 Linux shape), one that does neither.
case "$(uname -s)" in
  MINGW*|MSYS*)
    D="$(mktemp -d)"; trap 'rm -f "$CODE"; rm -rf "$D"' EXIT
    # supports: accepts the flag, honours the guard, exit 0
    printf '@echo off\r\nif "%%1"=="--reset-state" exit /b 0\r\nif "%%1"=="--help" echo   --reset-state  resets\r\nexit /b 0\r\n' > "$D/good.cmd"
    # LIAR: --help advertises it, the parser refuses it with exit 2
    # NO PARENTHESISED BLOCK HERE. `(echo ...^& exit /b 2)` parsed, ran, and
    # still exited 0 on this host, so the liar read as SUPPORTED -- a stub
    # that fails to lie is a green arm proving nothing. Plain lines instead.
    { printf '@echo off\r\n'
      printf 'if not "%%1"=="--reset-state" goto notreset\r\n'
      printf 'echo Unsupported option: --reset-state\r\n'
      printf 'exit /b 2\r\n'
      printf ':notreset\r\n'
      printf 'if "%%1"=="--help" echo   --reset-state  resets\r\n'
      printf 'exit /b 0\r\n'; } > "$D/liar.cmd"
    # silent: mentions nothing, refuses the flag
    printf '@echo off\r\nif "%%1"=="--reset-state" exit /b 2\r\nexit /b 0\r\n' > "$D/silent.cmd"

    # MSYS_NO_PATHCONV IS LOAD-BEARING, and its absence is not quiet: msys
    # rewrites the bare `/c` into a Windows path, cmd.exe then starts
    # INTERACTIVELY, prints its banner and exits 0 -- so every stub, liar
    # included, reads as "supported". Observed on this host before the export
    # was added. The installer itself is PowerShell and never sees this; it is
    # a hazard of driving cmd.exe from the fixture's shell, and the arms below
    # only mean anything with it set.
    export MSYS_NO_PATHCONV=1
    # The OLD rule, for contrast: does --help mention it?
    _help_says() { cmd.exe /c "$(cygpath -w "$1") --help" 2>&1 | grep -qF -- '--reset-state'; }
    # The NEW rule: attempt under the guard, read the exit code.
    _attempt_ok() { cmd.exe /c "set TILLANDSIAS_DESTRUCTIVE_RESET_OK=0&& $(cygpath -w "$1") --reset-state" >/dev/null 2>&1; }

    # SELF-CHECK before the arms: if the stubs are not actually running, the
    # arms are vacuous and the liar arm passes for the wrong reason.
    if ! cmd.exe /c "$(cygpath -w "$D/silent.cmd") --reset-state" >/dev/null 2>&1; then
        :
    else
        _bad "SELF-CHECK: the stub harness is not executing the stubs; arm 3 is vacuous"
    fi

    if _attempt_ok "$D/good.cmd"; then _ok "BEHAVIOURAL: a supporting binary is accepted by the attempt"
    else _bad "BEHAVIOURAL: a supporting binary was rejected by the attempt"; fi

    if _attempt_ok "$D/liar.cmd"; then
        _bad "BEHAVIOURAL: the LIAR was accepted -- the attempt rule is not working"
    else
        _ok "BEHAVIOURAL: the liar (--help advertises, parser refuses) is REJECTED"
    fi
    # ...and the contrast that makes the row: the old rule accepts the liar.
    if _help_says "$D/liar.cmd"; then
        _ok "CONTRAST: the old --help rule ACCEPTS the liar, which is the defect"
    else
        _bad "CONTRAST: the liar stub does not advertise in --help; it is not a liar and arm 3 proves nothing"
    fi

    if _attempt_ok "$D/silent.cmd"; then
        _bad "BEHAVIOURAL: a binary that refuses the flag was accepted"
    else
        _ok "BEHAVIOURAL: a binary that refuses the flag is rejected"
    fi
    ;;
  *)
    echo "skip: behavioural arm -- cmd.exe stubs need an msys locus (the source arms above still ran)"
    ;;
esac

[ "$fail" -eq 0 ] && echo "ok:installer-probes-by-attempt-not-by-help:all" || echo "FAIL:installer-probes-by-attempt-not-by-help"
exit "$fail"
