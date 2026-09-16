#!/usr/bin/env bash
# freshness: added 2026-09-15 linux-yoga (order 890-27mv)
# @trace order:890-27mv, order:856-s56y, order:1174-6r4k
#
# install-release-tier-timer.sh — arm a durable cadence for the tier the
# RELEASE gates on, so that tier is answered on a clock instead of at the
# moment somebody tries to ship.
#
# ── WHY THIS EXISTS (order 890-27mv) ─────────────────────────────────────────
#
# The recurring loop gates on `./build.sh --check`. The release gates on
# `--ci-full`. Nothing in between ever runs the quick litmus tier, and
# target/convergence/check-logs.jsonl is written only by scripts/local-ci.sh.
# So a release-blocking failure can ONLY surface at release time — the worst
# moment to discover it, and the reason a block is always a surprise.
#
# Measured on yoga 2026-09-15, months into daily attested cycles:
#   scripts/check-release-tier-freshness.sh
#     -> never:release-tier: no FULL-tier run in check-logs.jsonl
#   35 records present, every one of them phase-only.
# Not "the tier failed quietly". The tier has never been answered here.
#
# ── WHY A TIMER AND NOT A CYCLE STEP ─────────────────────────────────────────
#
# Folding the full tier into every cycle would make the cheap loop expensive
# and the expensive answer no fresher than the loop's slowest host. A separate,
# slower cadence keeps the two decoupled: the cycle stays a thing a floor host
# can finish, and the tier gets answered on a clock nobody has to remember.
#
# ── WHAT THIS DOES NOT DO ────────────────────────────────────────────────────
#
# It does not run the tier now. Installing a schedule and taking a measurement
# are different acts and conflating them is how an installer becomes something
# nobody dares run. Take the measurement with `scripts/local-ci.sh` directly.
#
# Idempotent: re-running re-renders and reloads.
#
# Usage:
#   scripts/install-release-tier-timer.sh [--interval 24h] [--boot-delay 45min]
#                                         [--timeout 180m] [--uninstall]
#
# Verdict grammar (exactly one line on stdout, last):
#   ^(ok:release-tier-timer-installed:interval=[^:]+:linger=(yes|already|failed)|ok:release-tier-timer-uninstalled|fail:install:[a-z-]+)$

set -u

INTERVAL=24h
BOOTDELAY=45min
TIMEOUT=180m
UNINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --interval) INTERVAL="${2:-}"; shift 2 ;;
        --boot-delay) BOOTDELAY="${2:-}"; shift 2 ;;
        --timeout) TIMEOUT="${2:-}"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        *) echo "usage: install-release-tier-timer.sh [--interval 24h] [--boot-delay 45min] [--timeout 180m] [--uninstall]" >&2; exit 2 ;;
    esac
done

for v in "$INTERVAL" "$BOOTDELAY" "$TIMEOUT"; do
    [ -n "$v" ] || { echo "fail:install:empty-argument"; exit 2; }
done

CHECKOUT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

command -v systemctl >/dev/null 2>&1 || { echo "fail:install:no-systemctl"; exit 1; }
systemctl --user show-environment >/dev/null 2>&1 || { echo "fail:install:no-user-session"; exit 1; }

if [ "$UNINSTALL" = 1 ]; then
    systemctl --user disable --now tillandsias-release-tier.timer >/dev/null 2>&1
    rm -f "$UNIT_DIR/tillandsias-release-tier.service" "$UNIT_DIR/tillandsias-release-tier.timer"
    systemctl --user daemon-reload
    echo "ok:release-tier-timer-uninstalled"
    exit 0
fi

mkdir -p "$UNIT_DIR"
for unit in service timer; do
    src="$CHECKOUT/packaging/systemd/user/tillandsias-release-tier.$unit.in"
    [ -f "$src" ] || { echo "fail:install:template-missing"; exit 1; }
    sed -e "s|@CHECKOUT@|$CHECKOUT|g" \
        -e "s|@INTERVAL@|$INTERVAL|g" \
        -e "s|@BOOTDELAY@|$BOOTDELAY|g" \
        -e "s|@TIMEOUT@|$TIMEOUT|g" \
        "$src" > "$UNIT_DIR/tillandsias-release-tier.$unit"
done

# A rendered unit that still carries a placeholder is a unit systemd will
# accept and then behave strangely under. Refuse rather than install it: an
# unsubstituted @TOKEN@ means a template gained a placeholder this script does
# not know about, which is silent drift between the two files.
if grep -l '@[A-Z]*@' "$UNIT_DIR/tillandsias-release-tier.service" \
                      "$UNIT_DIR/tillandsias-release-tier.timer" >/dev/null 2>&1; then
    rm -f "$UNIT_DIR/tillandsias-release-tier.service" "$UNIT_DIR/tillandsias-release-tier.timer"
    echo "fail:install:unsubstituted-placeholder"
    exit 1
fi

systemctl --user daemon-reload || { echo "fail:install:daemon-reload"; exit 1; }
systemctl --user enable --now tillandsias-release-tier.timer >/dev/null 2>&1 \
    || { echo "fail:install:enable-timer"; exit 1; }

LINGER="$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null)"
if [ "$LINGER" = "yes" ]; then
    LINGER_STATE="already"
elif loginctl enable-linger "$USER" >/dev/null 2>&1; then
    LINGER_STATE="yes"
else
    LINGER_STATE="failed"
fi

echo "ok:release-tier-timer-installed:interval=$INTERVAL:linger=$LINGER_STATE"
