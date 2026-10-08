#!/usr/bin/env bash
# @trace spec:host-state-lifecycle, order:1559-sqzp, order:1437-3iux
#
# test-installer-reset-kind.sh — install-windows.ps1 runs the SOFT reset and
# ONLY the SOFT reset, never prompts about it, and prints no power-user text.
#
# Operator ruling 2026-10-08, verbatim: "we do not ask end users to do power
# user stuff. That's our guideline. An install prompt asking for destructive
# cases should not be an acceptable case. End user is NOT a power user. No
# prompts like those, we make all the decisions for them, on their behalf, for
# their best interests. So SOFT reset is the default only and forever. A power
# user wanting to do a hard reset should be capable of figuring out where to
# place a flag and which flag, we do not need to print any power user messages
# during install, at all. Install should be for END USER (NOT POWER USER) and be
# a pretty installer, rather than an informational/debugging installer. As
# frictionless as possible for end users."
#
# Asserted over the installer's CODE (comments stripped), and over its RESET
# PATH (from `# BEGIN-RESET-PROBE` to the Installed-Software registration):
#   1 no HARD anywhere: no --reset-guest, --approve-hard-reset, -HardReset,
#     TILLANDSIAS_INSTALL_RESET, TILLANDSIAS_HARD_RESET_APPROVED or reset-kind
#     chooser (Get-TillandsiasResetPlan)
#   2 the reset is exactly one `--reset-state < NUL` (SOFT, stdin from NUL)
#   3 no Read-Host on the reset path
#   4 no output statement on the reset path names a flag, a variable, SOFT,
#     HARD, a reset or a probe
#   5 the tray's own reset log is not echoed into the installer's output
# Pre-fix (#247 at 0d1c6a852): FAILS — a HARD kind, a Read-Host prompt and a
# reset-kind first line.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/scripts/install-windows.ps1"
fails=0
pass() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# PowerShell comments: whole-line `#` and trailing ` # ...`; block comments
# (<# ... #>) only in the help header, which the strip below also drops.
code="$(awk '/^<#/ { inblk = 1 } inblk { if (/#>/) inblk = 0; next } { sub(/(^|[[:space:]])#.*/, ""); print }' "$SRC")"

nb="$(grep -cx '# BEGIN-RESET-PROBE' "$SRC")" || true
reg="$(grep -c 'Installed-Software registration' "$SRC")" || true
if [ "$nb" != "1" ] || [ "$reg" -lt 1 ]; then
    echo "fail:installer-reset-kind:reset-path-markers:probe=$nb:registration=$reg"
    exit 1
fi
reset_path="$(awk '/^# BEGIN-RESET-PROBE$/ { f = 1 } f && /Installed-Software registration/ { exit } f' "$SRC" \
    | awk '{ sub(/(^|[[:space:]])#.*/, ""); print }')"

# 1 — no HARD anywhere in the installer's code.
hard_hits=""
for tok in -- '--reset-guest' '--approve-hard-reset' 'HardReset' 'TILLANDSIAS_INSTALL_RESET' 'TILLANDSIAS_HARD_RESET_APPROVED' 'Get-TillandsiasResetPlan'; do
    [ "$tok" = "--" ] && continue
    if grep -qF -- "$tok" <<<"$code"; then hard_hits="$hard_hits $tok"; fi # sigpipe-ok: herestring, no upstream writer
done
if [ -z "$hard_hits" ]; then pass "1 no HARD path in the installer"; else bad "1 HARD path present:$hard_hits"; fi

# 2 — exactly one SOFT reset call, stdin from NUL.
soft_calls="$(grep -cF -- '--reset-state < NUL' <<<"$reset_path")" || true
if [ "$soft_calls" = "1" ]; then pass "2 one --reset-state call, stdin from NUL"; else bad "2 SOFT call count=$soft_calls"; fi

# 3 — the reset path never prompts.
if grep -qi 'Read-Host' <<<"$reset_path"; then bad "3 a Read-Host on the reset path"; else pass "3 no prompt on the reset path"; fi # sigpipe-ok: herestring, no upstream writer

# 4 — no power-user text in the reset path's output statements.
said="$(grep -E '(^|[[:space:]])(Say|SayOk|SayWn|Write-Host|Die)[[:space:]]' <<<"$reset_path")"
noisy="$(grep -iE -- '--[a-z]|TILLANDSIAS_|SOFT|HARD|reset|probe' <<<"$said" | grep -vF 'Get-Content')"
if [ -z "$noisy" ]; then pass "4 no flag, variable or reset-kind text in the output"; else bad "4 power-user text: $(printf '%s' "$noisy" | tr '\n' '|' | cut -c1-300)"; fi

# 5 — the tray's reset log is not echoed into the install.
if grep -qE 'Get-Content[^|]*\$ResetLog' <<<"$reset_path"; then bad "5 the tray's reset log is echoed"; else pass "5 the tray's reset log stays out of the output"; fi # sigpipe-ok: herestring, no upstream writer

if [ "$fails" -ne 0 ]; then
    echo "fail:installer-reset-kind:$fails"
    exit 1
fi
echo "ok:installer-reset-kind:5 arms"
