#!/usr/bin/env bash
# @trace order:1565-qtuk, spec:host-state-lifecycle
#
# Fixture for install-windows.ps1's reset path: ONE install provisions the
# guest ONCE, and that once is the SOFT reset. Measured on yolanda 2026-10-09
# (v56.10.9.1 W1 SOFT installs, twice): tray.log carried two
# "reset-state (SOFT): VM Ready" cycles per install, because the --reset-state
# capability probe ran with TILLANDSIAS_DESTRUCTIVE_RESET_OK=0, which skips the
# wipe but still provisions the existing state to Ready (~35 s), and only then
# did the real SOFT reset wipe and provision again.
#
# Cuts the reset path (from `# BEGIN-RESET-PROBE` to the Installed-Software
# registration) and RUNS it in
# PowerShell against a stub tray (.cmd, run by the installer's cmd.exe lines
# like the real exe). The stub logs each invocation, each SOFT wipe and each
# provisioning to a file; the opt-out makes it skip the wipe and still
# provision, exactly as reset_state_once does.
#
#   1  a supporting tray: exactly 1 provisioning AND exactly 1 SOFT wipe (the
#      fix must not get to "once" by skipping the reset), no Die, "ready" said
#      PRE-FIX RESULT: FAILS (provisions=2 wipes=1)
#   2  a supporting tray whose provisioning fails: 1 provisioning, Die names the
#      setup log, never a second attempt
#      PRE-FIX RESULT: FAILS (provisions=2)
#   3  a tray that rejects the flag (exit 2, unknown flag): 0 provisionings, no
#      Die, the restart-from-the-Start-menu line (the exit-2 discrimination)
#
# Needs Windows PowerShell or pwsh AND cmd.exe; skips by name without them.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/scripts/install-windows.ps1"
nb="$(grep -cx '# BEGIN-RESET-PROBE' "$SRC")" || true
reg="$(grep -c '^    # -- Installed-Software registration' "$SRC")" || true
if [ "$nb" != "1" ] || [ "$reg" != "1" ]; then
    echo "could-not-run:provisions-once-fixture:markers:begin=$nb:registration=$reg"
    exit 3
fi
PWSH="$(command -v powershell || command -v pwsh || true)"
if [ -z "$PWSH" ] || ! command -v cmd.exe >/dev/null 2>&1; then
    echo "skip:provisions-once-fixture:no-powershell-or-cmd-on-this-host"
    exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
win() { cygpath -w "$1"; }

# The reset path: a complete run of statements at the top level of the install.
awk '/^# BEGIN-RESET-PROBE$/ { f = 1 } /^    # -- Installed-Software registration/ { exit } f' "$SRC" > "$TMP/path.ps1"

# The stub tray. STUB_KIND=tray behaves like reset_state_once (the opt-out
# skips the wipe, provisioning always runs, exit STUB_EXIT); STUB_KIND=unknown
# is a tray from before --reset-state (refusal, exit 2, nothing done).
printf '%s\r\n' \
    '@echo off' \
    'echo call>>"%STUB_LOG%"' \
    'if "%STUB_KIND%"=="unknown" goto unknown' \
    'if "%TILLANDSIAS_DESTRUCTIVE_RESET_OK%"=="0" goto skip' \
    'echo [tillandsias] reset: SOFT' \
    'echo wipe>>"%STUB_LOG%"' \
    'echo provision>>"%STUB_LOG%"' \
    'exit /b %STUB_EXIT%' \
    ':skip' \
    'echo [tillandsias] --reset-state: reset skipped by TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 - reprovisioning through the platform plain init instead.' \
    'echo provision>>"%STUB_LOG%"' \
    'exit /b %STUB_EXIT%' \
    ':unknown' \
    'echo error: unknown flag --reset-state' \
    'exit /b 2' > "$TMP/tray.cmd"

cat > "$TMP/run.ps1" <<'PS'
param([string]$Path, [string]$Exe)
function Say   { param([string]$m) "say:$m" }
function SayOk { param([string]$m) "ok:$m" }
function SayWn { param([string]$m) "warn:$m" }
function Die   { param([string]$m) "die:$m"; exit 1 }
Remove-Item Env:TILLANDSIAS_DESTRUCTIVE_RESET_OK -ErrorAction SilentlyContinue
$InstalledExe = $Exe
. $Path
"end"
PS

fails=0
pass() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
# run <kind> <exit>: sets out, calls, provisions, wipes
run() {
    : > "$TMP/stub.log"
    out="$(STUB_KIND="$1" STUB_EXIT="$2" STUB_LOG="$(win "$TMP/stub.log")" TEMP="$(win "$TMP")" \
        "$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$(win "$TMP/run.ps1")" \
        -Path "$(win "$TMP/path.ps1")" -Exe "$(win "$TMP/tray.cmd")" 2>&1 | tr -d '\r')"
    calls="$(grep -c '^call$' "$TMP/stub.log")" || true
    provisions="$(grep -c '^provision$' "$TMP/stub.log")" || true
    wipes="$(grep -c '^wipe$' "$TMP/stub.log")" || true
}

# 1 — a supporting tray provisions once, through the SOFT reset.
run tray 0
if [ "$provisions" = "1" ] && [ "$wipes" = "1" ] && ! grep -q '^die:' <<<"$out" && grep -q '^ok:Tillandsias is ready' <<<"$out"; then # sigpipe-ok: herestring, no upstream writer
    pass "1 a supporting tray: one provisioning, and it is the SOFT reset (calls=$calls)"
else
    bad "1 supporting tray: provisions=$provisions wipes=$wipes calls=$calls out=[$(tr '\n' '|' <<<"$out" | cut -c1-300)]"
fi

# 2 — a failed provisioning is reported, never retried.
run tray 1
if [ "$provisions" = "1" ] && [ "$wipes" = "1" ] && grep -q '^die:.*tillandsias-setup\.log' <<<"$out"; then # sigpipe-ok: herestring, no upstream writer
    pass "2 a failed provisioning: one attempt, Die names the setup log"
else
    bad "2 failed provisioning: provisions=$provisions wipes=$wipes calls=$calls out=[$(tr '\n' '|' <<<"$out" | cut -c1-300)]"
fi

# 3 — a tray that predates the flag: no provisioning, no Die, restart line.
run unknown 2
if [ "$provisions" = "0" ] && [ "$wipes" = "0" ] && ! grep -q '^die:' <<<"$out" && grep -q '^warn:.*Restart it from the Start menu' <<<"$out"; then # sigpipe-ok: herestring, no upstream writer
    pass "3 a tray that rejects the flag (exit 2): nothing provisioned, restart line, no Die (calls=$calls)"
else
    bad "3 unknown flag: provisions=$provisions wipes=$wipes calls=$calls out=[$(tr '\n' '|' <<<"$out" | cut -c1-300)]"
fi

if [ "$fails" -gt 0 ]; then echo "refused:provisions-once-fixture:failed=$fails"; exit 1; fi
echo "ok:provisions-once-fixture:3"
