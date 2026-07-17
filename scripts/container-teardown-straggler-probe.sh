#!/usr/bin/env bash
# @trace spec:tray-app
# @trace plan/index.yaml container-teardown-straggler-probe (order 386)
#
# container-teardown-straggler-probe.sh — verify stack/terminal teardown leaves
# no straggling host processes behind (order 386, generalizes order 385).
#
# The operator's invariant: "tearing down containers leaves no straggling host
# processes." Order 385 fixes the spawn-time zombie class (unreaped
# terminal-launcher Child handles). This probe is the falsifiable regression
# guard: after a full stack teardown it asserts ZERO tray-parented Z-state
# (zombie) processes AND zero orphaned host-side terminal-launcher processes,
# and exits NONZERO if any straggler is found.
#
# Usage:
#   container-teardown-straggler-probe.sh [--tray-pid PID]
#
# With no --tray-pid, the probe locates the running tray process by matching
# `tillandsias` argv containing `--tray`. If no tray is running it scans the
# whole process tree for orphaned terminal launchers (parent PID 1 or a dead
# parent) and reports those — the orthogonal "orphan" half of the invariant.
#
# Emits a single human-readable summary line and exits 0 (clean) or 1 (stragglers).
set -uo pipefail

TRAY_PID=""
while [ $# -gt 0 ]; do
    case "$1" in
        --tray-pid) TRAY_PID="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done

# Terminal launchers we consider "host-side terminal spawn" children.
TERMINALS="ptyxis gnome-terminal kgx konsole xterm"

# Return the parent PID of a given pid from /proc/<pid>/status (PPid:).
ppid_of() {
    local p="$1"
    [ -r "/proc/$p/status" ] || { echo 0; return; }
    awk -F'\t' '/^PPid:/{print $2; exit}' "/proc/$p/status" 2>/dev/null || echo 0
}

# State char from /proc/<pid>/stat. The comm field (2) may contain spaces
# ("(tmux: server)"), so parse AFTER the last ')' instead of by field index.
state_of() {
    local p="$1"
    [ -r "/proc/$p/stat" ] || { echo "?"; return; }
    sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $1; exit}' || echo "?"
}

# Path of /proc/<pid>/exe basename (best-effort).
comm_of() {
    local p="$1"
    basename "$(readlink "/proc/$p/exe" 2>/dev/null || echo unknown)" 2>/dev/null
}

# Resolve the tray PID if not given.
if [ -z "$TRAY_PID" ]; then
    for p in /proc/[0-9]*; do
        pid="${p#/proc/}"
        cmdline="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)"
        case "$cmdline" in
            *tillandsias*"--tray"*) TRAY_PID="$pid"; break ;;
        esac
    done
fi

ZOMBIES=0
ORPHANS=0

if [ -n "$TRAY_PID" ] && [ -d "/proc/$TRAY_PID" ]; then
    # Z-state children directly parented to the tray.
    for c in /proc/[0-9]*; do
        cp="${c#/proc/}"
        [ "$(ppid_of "$cp")" = "$TRAY_PID" ] || continue
        [ "$(state_of "$cp")" = "Z" ] && ZOMBIES=$((ZOMBIES + 1))
    done
fi

# Orphaned host-side terminal-launcher processes: a known terminal binary whose
# parent is PID 1 (reparented after the tray/launcher died) or whose parent
# process no longer exists. These are the stragglers order 386 covers that
# order 385 does not (terminals opened INTO a container via `podman exec … ptyxis`).
for p in /proc/[0-9]*; do
    pid="${p#/proc/}"
    comm="$(comm_of "$pid")"
    case " $TERMINALS " in
        *" $comm "*) ;;
        *) continue ;;
    esac
    parent="$(ppid_of "$pid")"
    if [ "$parent" = "1" ] || [ ! -d "/proc/$parent" ]; then
        ORPHANS=$((ORPHANS + 1))
    fi
done

if [ "$ZOMBIES" -eq 0 ] && [ "$ORPHANS" -eq 0 ]; then
    echo "teardown-straggler: clean (zombies=$ZOMBIES orphans=$ORPHANS${TRAY_PID:+ tray=$TRAY_PID})"
    exit 0
fi

echo "teardown-straggler: STRAGGLERS FOUND (zombies=$ZOMBIES orphans=$ORPHANS${TRAY_PID:+ tray=$TRAY_PID})"
exit 1
