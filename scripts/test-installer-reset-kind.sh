#!/usr/bin/env bash
# @trace spec:host-state-lifecycle, order:1559-sqzp, order:1437-3iux
#
# test-installer-reset-kind.sh — install-windows.ps1 chooses SOFT by default and
# HARD only on request, and HARD only with a per-run approval it never grants
# itself (host-state-lifecycle "The installer runs SOFT for an update and HARD
# only when asked"; operator ruling 1443-bs9z).
#
# Runs the REAL `# BEGIN-RESET-KIND` .. `# END-RESET-KIND` block of the
# installer in PowerShell, the same extraction test-installer-reset-probe.sh
# uses, and asserts the decision for each input:
#   default                         -> soft, --reset-state, the spec's SOFT line
#   TILLANDSIAS_INSTALL_RESET=hard  -> hard selected; NOT approved by itself
#   -HardReset, no TTY, no variable -> refused with the spec's refusal
#   hard + TILLANDSIAS_HARD_RESET_APPROVED=1 -> --reset-guest (the variable
#                                      passes through; the installer adds nothing)
#   hard + TTY + typed HARD         -> --reset-guest --approve-hard-reset
#   hard + TTY + typed anything else -> refused
# and that the block never assigns TILLANDSIAS_HARD_RESET_APPROVED.
#
# Pre-fix: FAILS — the installer has no reset-kind block (markers absent).
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/scripts/install-windows.ps1"
nb="$(grep -cx '# BEGIN-RESET-KIND' "$SRC")" || true
ne="$(grep -cx '# END-RESET-KIND' "$SRC")" || true
if [ "$nb" != "1" ] || [ "$ne" != "1" ]; then
    echo "fail:installer-reset-kind:markers:begin=$nb:end=$ne"
    exit 1
fi
PWSH="$(command -v powershell || command -v pwsh || true)"
if [ -z "$PWSH" ]; then
    echo "skip:installer-reset-kind:no-powershell-on-this-host"
    exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sed -n '/^# BEGIN-RESET-KIND$/,/^# END-RESET-KIND$/p' "$SRC" > "$TMP/kind.ps1"
win() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# The block must not grant the approval itself (code only; comments stripped).
assign="$(sed 's/#.*//' "$TMP/kind.ps1")"
case "$assign" in
    *'$env:TILLANDSIAS_HARD_RESET_APPROVED'*'='*|*"SetEnvironmentVariable('TILLANDSIAS_HARD_RESET_APPROVED'"*)
        echo "fail:installer-reset-kind:the block sets TILLANDSIAS_HARD_RESET_APPROVED itself"
        exit 1 ;;
esac

cat > "$TMP/run.ps1" <<'PS'
param([string]$Kind, [string]$InstallReset, [string]$HardSwitch, [string]$Approved, [string]$Interactive, [string]$Typed)
. $Kind
$p = Get-TillandsiasResetPlan -InstallReset $InstallReset -HardSwitch ($HardSwitch -eq '1') `
    -ApprovedEnv $Approved -Interactive ($Interactive -eq '1') -Ask { if ($Typed -eq '__THROW__') { throw 'the prompt was shown' }; $Typed }
"kind=$($p.Kind)"
"args=$($p.Args -join ' ')"
"refused=$($p.Refused)"
"line=$($p.Line)"
PS

fails=0
run() { # run <install_reset> <hard_switch> <approved> <interactive> <typed>
    "$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$(win "$TMP/run.ps1")" \
        -Kind "$(win "$TMP/kind.ps1")" -InstallReset "$1" -HardSwitch "$2" \
        -Approved "$3" -Interactive "$4" -Typed "$5" 2>&1 | tr -d '\r'
}
expect() { # expect <label> <output> <needle>...
    local label="$1" out="$2"; shift 2
    for n in "$@"; do
        case "$out" in
            *"$n"*) ;;
            *) echo "FAIL: $label: missing [$n] in: $(printf '%s' "$out" | tr '\n' '|')"; fails=$((fails + 1)); return ;;
        esac
    done
    echo "ok:   $label"
}
SOFT_LINE='line=install: SOFT reset (stores and sign-ins kept); TILLANDSIAS_INSTALL_RESET=hard for a full guest wipe'
REFUSAL='refused=reset: HARD requires per-run approval (TILLANDSIAS_HARD_RESET_APPROVED=1 or --approve-hard-reset)'

expect "default is SOFT"                   "$(run '' 0 '' 0 '')"      'kind=soft' 'args=--reset-state' "$SOFT_LINE" 'refused='
expect "install-reset=hard selects only"   "$(run hard 0 '' 0 '')"    'kind=hard' 'args=' "$REFUSAL"
expect "-HardReset without approval"       "$(run '' 1 '' 0 '')"      'kind=hard' "$REFUSAL"
expect "approved=true is not approval"     "$(run hard 0 true 0 '')"  "$REFUSAL"
expect "approved=1 passes through"         "$(run hard 0 1 1 __THROW__)"     'kind=hard' 'args=--reset-guest' 'refused='
expect "TTY + HARD typed"                  "$(run '' 1 '' 1 HARD)"    'args=--reset-guest --approve-hard-reset' 'refused='
expect "TTY + other word"                  "$(run '' 1 '' 1 hard)"    "$REFUSAL"
expect "TTY + empty"                       "$(run hard 0 '' 1 '')"    "$REFUSAL"
# A soft run must not prompt: with -Interactive and a typed HARD it stays soft.
expect "soft never prompts"                "$(run '' 0 '' 1 __THROW__)"    'kind=soft' 'args=--reset-state'

if [ "$fails" -ne 0 ]; then
    echo "fail:installer-reset-kind:$fails"
    exit 1
fi
echo "ok:installer-reset-kind:9 arms"
