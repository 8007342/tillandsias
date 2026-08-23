#!/usr/bin/env bash
# freshness: added 2026-08-23 linux-yoga (order 856-s56y)
# @trace order:856-s56y
#
# check-cycle-scheduler.sh — is a durable unattended-cycle scheduler armed on
# THIS host, and what did it last do? (856-s56y exit criterion 5: an operator
# asks "when did you last fire, when do you fire next, did the last one
# succeed" without reading a transcript.)
#
# Linux/systemd implementation; the launchd and Task Scheduler children of
# 856-s56y answer the same grammar on their platforms.
#
# Verdict grammar (exactly one line on stdout):
#   ok:cycle-scheduler:next=<ts|pending-current-cycle>:last=<ts|never>:lastrc=<n|none>
#   due:not-installed        units absent — run scripts/install-cycle-timer.sh
#   due:timer-inactive       installed but not running (systemctl --user start)
#   due:linger-off           armed but dies at logout — loginctl enable-linger
#   unavailable:no-systemd-user
# Exit 0 only on ok:*; 1 on due:*; 2 on unavailable/usage.
set -uo pipefail

command -v systemctl >/dev/null 2>&1 || { echo "unavailable:no-systemd-user"; exit 2; }
systemctl --user show-environment >/dev/null 2>&1 || { echo "unavailable:no-systemd-user"; exit 2; }

state="$(systemctl --user show tillandsias-cycle.timer --property=ActiveState --value 2>/dev/null)"
if [ -z "$state" ] || [ "$state" = "inactive" ] && ! systemctl --user cat tillandsias-cycle.timer >/dev/null 2>&1; then
    echo "due:not-installed"
    exit 1
fi
if [ "$state" != "active" ]; then
    echo "due:timer-inactive"
    exit 1
fi

LINGER="$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null)"
if [ "$LINGER" != "yes" ]; then
    echo "due:linger-off"
    exit 1
fi

# Two systemd property traps, both measured live on systemd 258: `show`
# prints timestamp properties as FORMATTED strings, not microseconds, despite
# the USec name — and for a monotonic (OnUnitInactiveSec) timer
# NextElapseUSecRealtime is UNSET even while `list-timers` happily computes
# the wall-clock NEXT. So read list-timers (LC_ALL=C pins the column format),
# whose NEXT is `-` exactly when the service is currently running — the
# interval starts at completion, so say so rather than inventing a timestamp.
next_line="$(LC_ALL=C systemctl --user list-timers tillandsias-cycle.timer --no-legend --no-pager 2>/dev/null | head -1)"
next_raw="$(printf '%s\n' "$next_line" | awk '{print $1" "$2" "$3" "$4}')"
case "$next_raw" in
    "- "*|""|"   ")
        NEXT="pending-current-cycle" ;;
    *)
        NEXT="$(date -u -d "$next_raw" +%FT%TZ 2>/dev/null || echo "unparseable")" ;; # gnu-date: ok (unreachable off-Linux: the systemctl --user guards above exit unavailable:no-systemd-user first)
esac

LOG="${TILLANDSIAS_CYCLE_STATE_DIR:-$HOME/.cache/tillandsias}/cycle-scheduler.jsonl"
LAST="never"; LASTRC="none"
if [ -s "$LOG" ]; then
    lastline="$(tail -1 "$LOG")"
    LAST="$(printf '%s' "$lastline" | sed -n 's/.*"ts_end":"\([^"]*\)".*/\1/p')"
    LASTRC="$(printf '%s' "$lastline" | sed -n 's/.*"rc":\([0-9]*\).*/\1/p')"
    [ -n "$LAST" ] || LAST="never"
    [ -n "$LASTRC" ] || LASTRC="none"
fi

echo "ok:cycle-scheduler:next=$NEXT:last=$LAST:lastrc=$LASTRC"
