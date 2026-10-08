#!/usr/bin/env bash
# @trace order:1561-9f4x, order:1561-47a8, spec:host-state-lifecycle
#
# check-installer-end-user-output.sh — the END-USER installers print only
# end-user lines. Operator ruling 2026-10-08, verbatim: "we do not need to print
# any power user messages during install, at all. Install should be for END USER
# (NOT POWER USER) and be a pretty installer, rather than an
# informational/debugging installer. As frictionless as possible for end users."
#
# A DIAGNOSTIC OUTPUT LINE is a user-facing output statement whose text names a
# --flag, a TILLANDSIAS_* variable, a URL, a channel or a base. Output
# statements: Say / SayOk / SayWn / Write-Host / Die in PowerShell; say / die /
# echo / printf in shell. Comments are stripped first. Two exemptions, both
# visible in the source:
#   - a line marked `# power-user-only`: reachable only when a power user passes
#     a bad flag (usage and argument errors), never on the normal path;
#   - a region between `# BEGIN-PENDING-1560-UAM3` and `# END-PENDING-1560-UAM3`:
#     the .wslconfig and Hyper-V prompt blocks the operator left "for now";
#     their removal (1560-uam3) removes the markers and the text with them.
# Diagnostics belong in the installer's log file, shown by path on failure.
#
# FLOORS: scripts/portability/installer-end-user-output-floor.txt, one
# "<installer> <count>" line each. Above the floor is refused, naming every line
# by file:line; below it passes with a note to lower the floor. Each platform
# slice of 1561-9f4x drops its installer to 0.
#
# TILLANDSIAS_INSTALLER_OUTPUT_ROOT is the fixture seam
# (scripts/test-check-installer-end-user-output.sh).
set -uo pipefail
ROOT="${TILLANDSIAS_INSTALLER_OUTPUT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
FLOORS="$ROOT/scripts/portability/installer-end-user-output-floor.txt"
[ -f "$FLOORS" ] || { echo "refused:installer-end-user-output:floor-file-missing:$FLOORS"; exit 1; }

refused=0
summary=""
while read -r f floor; do
    case "$f" in '' | '#'*) continue ;; esac
    case "$floor" in '' | *[!0-9]*) echo "refused:installer-end-user-output:floor-unreadable:$f"; exit 1 ;; esac
    [ -f "$ROOT/$f" ] || { echo "refused:installer-end-user-output:installer-missing:$f"; exit 1; }
    case "$f" in *.ps1) lang=ps ;; *) lang=sh ;; esac
    hits="$(awk -v f="$f" -v lang="$lang" '
        /^<#/ { blk = 1 } blk { if (/#>/) blk = 0; next }
        /#[[:space:]]*BEGIN-PENDING-1560-UAM3/ { pend = 1; next }
        /#[[:space:]]*END-PENDING-1560-UAM3/ { pend = 0; next }
        pend { next }
        /#[[:space:]]*power-user-only/ { next }
        { line = $0; sub(/(^|[[:space:]])#.*/, "", line) }
        lang == "ps" && line !~ /(^|[[:space:];{(])(Say|SayOk|SayWn|Write-Host|Die)[[:space:]]/ { next }
        lang == "sh" && line !~ /(^|[[:space:];{(|&])(say|die|echo|printf)[[:space:]]/ { next }
        line ~ /--[a-z]|TILLANDSIAS_|https?:|[Cc]hannel|base:/ { print f ":" NR }
    ' "$ROOT/$f")"
    count=0
    [ -n "$hits" ] && count="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
    if [ "$count" -gt "$floor" ]; then
        echo "refused:installer-end-user-output:$f:count=$count:floor=$floor:$(printf '%s' "$hits" | tr '\n' ' ')"
        refused=1
    elif [ "$count" -lt "$floor" ]; then
        summary="$summary $f=$count<floor=$floor(lower-the-floor)"
    else
        summary="$summary $f=$count"
    fi
done < "$FLOORS"

if [ "$refused" -ne 0 ]; then
    echo "  why: an end-user installer prints power-user or diagnostic text (operator ruling 2026-10-08)" >&2
    echo "  remedy: write the detail to the installer's log and print a plain end-user line; mark a usage error # power-user-only" >&2
    exit 1
fi
echo "ok:installer-end-user-output:${summary# }"
exit 0
