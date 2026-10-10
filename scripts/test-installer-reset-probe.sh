#!/usr/bin/env bash
# @trace order:1449-4qqu, order:1565-qtuk
#
# Fixture for install-windows.ps1's --reset-state probe. The installer carries
# the probe between two exact-once marker lines; this cuts that block and RUNS
# it in PowerShell against stub trays (.cmd files, which the probe's cmd.exe
# line runs like the real exe), then reads $HasResetState.
#
# SINCE 1565-qtuk THE PROBE IS THE SOFT RESET CALL ITSELF: the separate probe
# ran with the opt-out, which skips the wipe but still provisions, so every
# install provisioned twice. $HasResetState now means "the parser took the
# flag" (anything but exit 2), and a non-zero verdict of a reset that RAN is
# the installer's Die, not "this tray predates the flag".
#
#   0  both markers exactly once (could-not-run otherwise)
#   A  unknown flag: prints a refusal, exit 2          -> unsupported
#   B  flag accepted, re-init FAILED: skip line, exit 1 -> SUPPORTED
#      PRE-FIX RESULT: FAILS (read as "predates --reset-state"; measured on
#      yolanda 2026-09-27 with v56.9.27.2)
#   C  flag accepted, re-init ok: skip line, exit 0    -> supported
#   D  some other failure, no skip line, exit 1        -> SUPPORTED since
#      1565-qtuk (was unsupported: the conservative direction then refused to
#      authorise a LATER destructive call; there is no later call now, and
#      reading a failed reset as "old tray" would hide it behind a restart
#      hint instead of the Die that names the setup log)
#
# Needs Windows PowerShell or pwsh AND cmd.exe; skips by name without them.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/scripts/install-windows.ps1"
nb="$(grep -cx '# BEGIN-RESET-PROBE' "$SRC")" || true
ne="$(grep -cx '# END-RESET-PROBE' "$SRC")" || true
if [ "$nb" != "1" ] || [ "$ne" != "1" ]; then
    echo "could-not-run:reset-probe-fixture:markers:begin=$nb:end=$ne"
    exit 3
fi
PWSH="$(command -v powershell || command -v pwsh || true)"
if [ -z "$PWSH" ] || ! command -v cmd.exe >/dev/null 2>&1; then
    echo "skip:reset-probe-fixture:no-powershell-or-cmd-on-this-host"
    exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sed -n '/^# BEGIN-RESET-PROBE$/,/^# END-RESET-PROBE$/p' "$SRC" > "$TMP/probe.ps1"
win() { cygpath -w "$1"; }

stub() { # stub <name> <line or empty> <exit>
    if [ -n "$2" ]; then
        printf '@echo off\r\necho %s\r\nexit /b %s\r\n' "$2" "$3" > "$TMP/$1.cmd"
    else
        printf '@echo off\r\nexit /b %s\r\n' "$3" > "$TMP/$1.cmd"
    fi
}
SKIP='[tillandsias] --reset-state: reset skipped by TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 - reprovisioning through the platform''s plain init instead.'
stub unknown 'error: unknown flag --reset-state' 2
stub failed "$SKIP" 1
stub ok "$SKIP" 0
stub other 'panicked at something unrelated' 1

cat > "$TMP/run.ps1" <<'PS'
param([string]$Probe, [string]$Exe)
function Say { param([string]$m) }
function SayWn { param([string]$m) }
$InstalledExe = $Exe
. $Probe
"has=$HasResetState"
PS
fails=0
expect() { # expect <stub> <True|False> <label>
    local got
    got="$(TEMP="$(win "$TMP")" "$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$(win "$TMP/run.ps1")" -Probe "$(win "$TMP/probe.ps1")" -Exe "$(win "$TMP/$1.cmd")" 2>&1 | tr -d '\r' | grep '^has=' || true)"
    if [ "$got" = "has=$2" ]; then
        echo "ok:   $3 ($got)"
    else
        echo "FAIL: $3: expected has=$2, got '${got:-no result}'"
        fails=$((fails + 1))
    fi
}
expect unknown False "A unknown flag is unsupported"
expect failed True "B flag accepted, re-init failed, is SUPPORTED"
expect ok True "C flag accepted, re-init ok, is supported"
expect other True "D a failure of a reset that ran is SUPPORTED (the installer Dies on it)"
if [ "$fails" -gt 0 ]; then echo "refused:reset-probe-fixture:failed=$fails"; exit 1; fi
echo "ok:reset-probe-fixture:4"
