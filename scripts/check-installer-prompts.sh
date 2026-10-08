#!/usr/bin/env bash
# @trace order:1560-g5d9, spec:host-state-lifecycle
#
# check-installer-prompts.sh — a RATCHET on interactive prompts in the END-USER
# installers. Operator ruling 2026-10-08, verbatim: "we do not ask end users to
# do power user stuff. That's our guideline. An install prompt asking for
# destructive cases should not be an acceptable case. End user is NOT a power
# user. No prompts like those, we make all the decisions for them, on their
# behalf, for their best interests. ... Install should be for END USER (NOT
# POWER USER) and be a pretty installer, rather than an informational/debugging
# installer. As frictionless as possible for end users."
#
# POPULATION: scripts/install.sh, scripts/install-macos.sh,
# scripts/install-windows.ps1. NOT scripts/uninstall.sh: host-state-lifecycle
# REQUIRES --uninstall to ask before removing ~/.tillandsias/.
# A PROMPT is a code line (comments stripped) carrying Read-Host, `read ... -p`,
# or a [y/N] / [Y/n] choice.
#
# FLOOR: scripts/portability/installer-prompt-floor.txt (2 on 2026-10-08: the
# .wslconfig and Hyper-V prompts in install-windows.ps1, left "for now"; their
# removal is 1560-uam3, unscheduled). Above the floor is refused, naming every
# prompt by file:line; below it passes with a note to lower the floor.
#
# TILLANDSIAS_INSTALLER_PROMPT_ROOT is the fixture seam
# (scripts/test-check-installer-prompts.sh).
set -uo pipefail
ROOT="${TILLANDSIAS_INSTALLER_PROMPT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
FLOOR_FILE="$ROOT/scripts/portability/installer-prompt-floor.txt"
POP="scripts/install.sh scripts/install-macos.sh scripts/install-windows.ps1"

floor="$(grep -vE '^[[:space:]]*(#|$)' "$FLOOR_FILE" 2>/dev/null | head -1 | tr -d '[:space:]')"
case "$floor" in
    '' | *[!0-9]*)
        echo "refused:installer-prompts:floor-unreadable:$FLOOR_FILE"
        exit 1 ;;
esac

sites=""
count=0
for f in $POP; do
    [ -f "$ROOT/$f" ] || { echo "refused:installer-prompts:population-missing:$f"; exit 1; }
    # Read-Host counts in PowerShell; `read -p` counts in shell, and only as a
    # COMMAND (statement start or after ; & | ( ), because prose like "could not
    # read this host's ... guest-shape" otherwise matches (measured on the first
    # run against install-windows.ps1:437). A [y/N] choice counts in both.
    case "$f" in *.ps1) lang=ps ;; *) lang=sh ;; esac
    hits="$(awk -v f="$f" -v lang="$lang" '
        /^<#/ { blk = 1 } blk { if (/#>/) blk = 0; next }
        { line = $0; sub(/(^|[[:space:]])#.*/, "", line) }
        (lang == "ps" && line ~ /Read-Host/) ||
        (lang == "sh" && line ~ /(^|[;&|(])[[:space:]]*read[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*p([[:space:]]|$)/) ||
        line ~ /\[[yY]\/[nN]\]/ { print f ":" NR }
    ' "$ROOT/$f")"
    if [ -n "$hits" ]; then
        sites="$sites $hits"
        count=$((count + $(printf '%s\n' "$hits" | wc -l)))
    fi
done
sites="$(printf '%s' "$sites" | tr '\n' ' ' | sed 's/^ *//; s/ *$//')"

if [ "$count" -gt "$floor" ]; then
    echo "refused:installer-prompts:count=$count:floor=$floor:$sites"
    echo "  why: an end-user installer asks the user something (operator ruling 2026-10-08: no prompts; the installer decides)" >&2
    echo "  remedy: decide on the user's behalf and remove the prompt; the sites are listed above" >&2
    exit 1
fi
if [ "$count" -lt "$floor" ]; then
    echo "ok:installer-prompts:count=$count:floor=$floor — lower the floor in scripts/portability/installer-prompt-floor.txt to $count"
    exit 0
fi
echo "ok:installer-prompts:count=$count:floor=$floor"
exit 0
