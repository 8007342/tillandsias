#!/usr/bin/env bash
# freshness: added 2026-08-23 linux-yoga (order 856-s56y)
# @trace order:856-s56y
#
# install-cycle-timer.sh — arm the durable Linux scheduler for unattended
# Tillandsias cycles: render packaging/systemd/user/tillandsias-cycle.{service,
# timer}.in for THIS checkout, install them as systemd USER units, enable the
# timer now and at boot, and enable lingering so the whole thing survives
# logout — the property ./repeat lacks and the attestation gaps are made of.
#
# Idempotent: re-running re-renders and reloads. Per-host interval (856-s56y
# exit criterion 3): pass --interval; operator mandate is 4h for roughly-4-core
# hosts, 1h-2h for fast hosts.
#
# Usage:
#   scripts/install-cycle-timer.sh --interval 2h [--boot-delay 10min] [--uninstall]
#
# Verdict grammar (exactly one line on stdout, last):
#   ^(ok:cycle-timer-installed:interval=[^:]+:linger=(yes|already|failed)|ok:cycle-timer-uninstalled|fail:install:[a-z-]+)$
set -uo pipefail

INTERVAL="1h"
BOOTDELAY="10min"
UNINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --interval) shift; INTERVAL="${1:?--interval needs a value}" ;;
        --boot-delay) shift; BOOTDELAY="${1:?--boot-delay needs a value}" ;;
        --uninstall) UNINSTALL=1 ;;
        *) echo "usage: install-cycle-timer.sh [--interval 2h] [--boot-delay 10min] [--uninstall]" >&2; exit 2 ;;
    esac
    shift
done

CHECKOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

command -v systemctl >/dev/null 2>&1 || { echo "fail:install:no-systemctl"; exit 1; }
systemctl --user show-environment >/dev/null 2>&1 || { echo "fail:install:no-user-session"; exit 1; }

if [ "$UNINSTALL" = 1 ]; then
    systemctl --user disable --now tillandsias-cycle.timer >/dev/null 2>&1
    rm -f "$UNIT_DIR/tillandsias-cycle.service" "$UNIT_DIR/tillandsias-cycle.timer"
    systemctl --user daemon-reload
    echo "ok:cycle-timer-uninstalled"
    exit 0
fi

mkdir -p "$UNIT_DIR"
for unit in service timer; do
    src="$CHECKOUT/packaging/systemd/user/tillandsias-cycle.$unit.in"
    [ -f "$src" ] || { echo "fail:install:template-missing"; exit 1; }
    sed -e "s|@CHECKOUT@|$CHECKOUT|g" \
        -e "s|@INTERVAL@|$INTERVAL|g" \
        -e "s|@BOOTDELAY@|$BOOTDELAY|g" \
        "$src" > "$UNIT_DIR/tillandsias-cycle.$unit"
done

systemctl --user daemon-reload || { echo "fail:install:daemon-reload"; exit 1; }
systemctl --user enable --now tillandsias-cycle.timer >/dev/null 2>&1 \
    || { echo "fail:install:enable-timer"; exit 1; }

# Lingering: without it every user unit dies at logout, exactly like the
# foreground loop this replaces. `loginctl enable-linger` for one's own user
# needs no privilege on stock Fedora; report rather than die if policy differs.
LINGER="$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null)"
if [ "$LINGER" = "yes" ]; then
    LINGER_STATE="already"
elif loginctl enable-linger "$USER" >/dev/null 2>&1; then
    LINGER_STATE="yes"
else
    LINGER_STATE="failed"
fi

echo "ok:cycle-timer-installed:interval=$INTERVAL:linger=$LINGER_STATE"
[ "$LINGER_STATE" != "failed" ]
