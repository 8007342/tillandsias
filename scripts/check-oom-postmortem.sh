#!/usr/bin/env bash
# @trace order:1176-fn2p
#
# After a child dies on a signal, ask the KERNEL whether it killed it for memory
# — so a gate can say refused:gate:oom-killed instead of stopping mid-line.
#
# WHY A POST-MORTEM AT ALL. SIGKILL leaves no exit path, so the victim writes
# nothing: the log simply stops. A reader cannot tell an OOM from a hang, and
# those need OPPOSITE responses — wait longer versus stop and hand off
# (1176-fn2p). The kernel does record the kill; until now nothing read it back.
#
# THREE STATES, NEVER TWO (965-sxec). "No OOM record" and "could not look" are
# different facts and must not collapse: a host whose journal this user cannot
# read would otherwise report a confident not-OOM for every kill.
#
#   0  ok:no-oom-record         looked, and the kernel records no kill in the window
#   1  refused:gate:oom-killed  the kernel records an OOM kill in the window
#   3  could-not-run:...        could not look, and says so
#
# THE POSITIVE CONTROL IS NOT OPTIONAL. `journalctl -k -g <pattern>` prints "No
# entries" and exits 0 both when the window is genuinely quiet AND when this
# user cannot read the kernel journal at all — identical output for opposite
# facts. So this asks first whether ANY kernel line is readable, and degrades to
# could-not-run when none is. Measured on yoga (Silverblue, unprivileged):
# `journalctl -k` returns lines, while `dmesg` is "Operation not permitted" —
# which is exactly why the journal is the source here and dmesg is not.
set -uo pipefail

SINCE="-15min"
VICTIM=""
JOURNAL_FROM=""

while [ $# -gt 0 ]; do
    case "$1" in
        --since)        SINCE="${2:-}"; shift 2 ;;
        --victim)       VICTIM="${2:-}"; shift 2 ;;
        --journal-from) JOURNAL_FROM="${2:-}"; shift 2 ;;
        *) echo "usage: check-oom-postmortem.sh [--since SPEC] [--victim NAME] [--journal-from FILE]" >&2; exit 2 ;;
    esac
done

_oom_pattern='Out of memory|oom-kill|Killed process|oom_reaper'

if [ -n "$JOURNAL_FROM" ]; then
    # The fixture seam. A file stands in for the kernel journal so the arms are
    # hermetic: an OOM cannot be provoked on demand, and a host that has never
    # OOMed would otherwise be unable to test the positive case at all.
    if [ ! -r "$JOURNAL_FROM" ]; then
        echo "could-not-run:oom-postmortem:unreadable-seam:$JOURNAL_FROM"
        exit 3
    fi
    _lines="$(cat "$JOURNAL_FROM")"
    _control_ok=1
else
    command -v journalctl >/dev/null 2>&1 || {
        echo "could-not-run:oom-postmortem:no-journalctl (this host records no readable kernel log here; nothing is asserted about why the child died)"
        exit 3
    }
    # POSITIVE CONTROL FIRST — can this user read the kernel journal at all?
    _probe="$(journalctl -k --since "$SINCE" -n 1 --no-pager 2>/dev/null | sed '/^-- /d')"
    if [ -z "$_probe" ]; then
        # Widen once before concluding: a genuinely quiet 15 minutes on an idle
        # host is possible, and would otherwise read as "cannot see".
        _probe="$(journalctl -k -n 1 --no-pager 2>/dev/null | sed '/^-- /d')"
    fi
    if [ -z "$_probe" ]; then
        echo "could-not-run:oom-postmortem:kernel-journal-unreadable (no kernel line is readable by this user, so an empty OOM search proves nothing)"
        exit 3
    fi
    _control_ok=1
    _lines="$(journalctl -k --since "$SINCE" --no-pager 2>/dev/null | grep -E "$_oom_pattern" || true)"
fi

[ "$_control_ok" = "1" ] || { echo "could-not-run:oom-postmortem:no-control"; exit 3; }

_hits="$(printf '%s\n' "$_lines" | grep -E "$_oom_pattern" || true)"
if [ -n "$VICTIM" ] && [ -n "$_hits" ]; then
    # NARROWED, NOT FILTERED AWAY. When a victim name is given, only a record
    # naming it counts — otherwise an unrelated OOM elsewhere on the host would
    # launder an ordinary failure into refused:gate:oom-killed, which is
    # 1176-fn2p's second negative control.
    _hits="$(printf '%s\n' "$_hits" | grep -F "$VICTIM" || true)"
fi

if [ -n "$_hits" ]; then
    echo "refused:gate:oom-killed (the kernel records an OOM kill in the last $SINCE${VICTIM:+ naming $VICTIM})"
    printf '%s\n' "$_hits" | tail -3 | sed 's/^/  /'
    exit 1
fi

echo "ok:no-oom-record (kernel journal readable and records no OOM kill in the last $SINCE${VICTIM:+ naming $VICTIM})"
exit 0
