#!/usr/bin/env bash
# @trace order:1385-h6uz
#
# opencode-tool-start-follower — announce each opencode tool call when it
# STARTS, on the lane's own stdout.
#
# WHY. A prompted `opencode run` prints a tool call only when the call
# COMPLETES, in the default format and in `--format json` alike, and
# `--print-logs` goes quiet after startup (measured 2026-09-26, opencode
# 1.18.30 on a Mac host and 1.18.32 in the forge). So an agent inside one long
# call (a cargo build) is silent for as long as the call runs: the macOS smoke
# of v56.9.25.2 ran three hours with no output. opencode's own log DOES record
# each call at its start, as
#   … message=evaluated permission=bash pattern="<the command>" …
# (in the forge: 13:39:50.047Z for a `sleep 5` that finished at 13:39:55).
# This follows that log and echoes one line per new call:
#   [forge] tool start: <permission>: <pattern>
#
# FAIL-LOUD. If the log never appears within the grace period, it says so,
# instead of a silent lane becoming a silent follower.
#
# Usage: opencode-tool-start-follower [<log file>] [<grace seconds>]
#   defaults: ${XDG_DATA_HOME:-$HOME/.local/share}/opencode/log/opencode.log, 30
# Runs until killed; the caller starts it in the background.
set -u

LOG="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/log/opencode.log}"
GRACE="${2:-30}"

waited=0
while [ ! -e "$LOG" ]; do
    if [ "$waited" -ge "$GRACE" ]; then
        echo "[forge] WARN: tool-start follower: opencode log never appeared at $LOG after ${GRACE}s; tool calls will print only when they finish (1385-h6uz)"
        exit 3
    fi
    sleep 1
    waited=$((waited + 1))
done

# -n 0: only lines written from now on, never an earlier run's history.
# -F: keep following across rotation or re-creation.
tail -n 0 -F "$LOG" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        *"message=evaluated permission="*) ;;
        *) continue ;;
    esac
    perm="${line#*message=evaluated permission=}"
    perm="${perm%% *}"
    pat="${line#*pattern=}"
    case "$pat" in
        \"*) pat="${pat#\"}"; pat="${pat%%\" action.*}" ;;
        *)   pat="${pat%% *}" ;;
    esac
    printf '[forge] tool start: %s: %s\n' "$perm" "$pat"
done
