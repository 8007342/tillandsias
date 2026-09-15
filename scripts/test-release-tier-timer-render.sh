#!/usr/bin/env bash
# freshness: added 2026-09-15 linux-yoga (order 890-27mv)
# @trace order:890-27mv, order:1174-6r4k
#
# test-release-tier-timer-render.sh — does the release-tier installer render a
# unit that answers the question the release actually gates on?
#
# ── REGIME ───────────────────────────────────────────────────────────────────
# HERMETIC, and specifically it ARMS NOTHING. Every case points
# XDG_CONFIG_HOME at a mktemp -d, so the installer writes its units there and
# never into the real ~/.config/systemd/user. The installer's final
# `systemctl --user enable --now` therefore CANNOT find the unit and fails —
# that failure is expected and is the sandbox working, not a defect. The
# assertions are all about the FILES it rendered before that point.
#
# This matters more than the usual hermeticity: the thing under test installs a
# recurring job. A fixture that armed it as a side effect would leave a timer
# firing on whatever host ran the suite, which is the one outcome nobody would
# notice until it had been running for a week.
#
# No absolute timestamp appears here. The fixture asserts properties of a
# rendered unit, and those do not expire on a date.
#
# ── WHAT IS WORTH ASSERTING, and why it is not "the file exists" ─────────────
# The defect this order is about is a tier that answers only at release time.
# A timer that fired `local-ci.sh --phase pre-build` on a beautiful schedule
# would look exactly like the fix and preserve the defect exactly, because
# check-release-tier-freshness.sh reads a phase-only record as NO ANSWER AT
# ALL (1174-6r4k). So the load-bearing assertion is about the ABSENCE of a
# --phase argument, which is an easy thing to leave out of a test and the only
# thing that makes the timer worth installing.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/scripts/install-release-tier-timer.sh"
[ -x "$INSTALLER" ] || { echo "FAIL: installer not executable at $INSTALLER"; exit 1; }

pass=0; fail=0
_ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
_bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

# Render into a sandbox and echo the unit dir. The installer's enable step
# fails in here by design; we ignore its exit and read what it wrote.
_render() {
    d="$1"; shift
    XDG_CONFIG_HOME="$d" "$INSTALLER" "$@" >"$d/verdict.txt" 2>"$d/err.txt" || true
    printf '%s\n' "$d/systemd/user"
}

sandbox="$(mktemp -d)"
units="$(_render "$sandbox" --interval 24h --boot-delay 45min --timeout 180m)"

# --- 1. both units are rendered into the sandbox, not into the real config ---
if [ -f "$units/tillandsias-release-tier.service" ] && [ -f "$units/tillandsias-release-tier.timer" ]; then
    _ok "both units render"
else
    _bad "both units render" "missing under $units"
fi

# --- 2. THE LOAD-BEARING ONE: the service runs the FULL tier ----------------
exec_line="$(grep '^ExecStart=' "$units/tillandsias-release-tier.service" 2>/dev/null || true)"
case "$exec_line" in
    *--phase*)
        _bad "the service runs the FULL tier, not a phase" \
             "ExecStart carries --phase, which check-release-tier-freshness.sh reads as no answer at all: $exec_line" ;;
    *local-ci.sh*)
        _ok "the service runs local-ci.sh with no --phase (a full-tier answer)" ;;
    *)
        _bad "the service runs the FULL tier, not a phase" "unexpected ExecStart: ${exec_line:-<absent>}" ;;
esac

# --- 3. the timer actually carries a schedule -------------------------------
# Written as a grep for an "=" assignment rather than a guessed directive name:
# reaching for OnCalendar|OnUnitActive and finding nothing is how a present
# OnUnitInactiveSec reads as an absent schedule (measured on this host today).
sched="$(grep -cE '^(OnCalendar|OnUnitInactiveSec|OnUnitActiveSec|OnBootSec|OnActiveSec)=' \
    "$units/tillandsias-release-tier.timer" 2>/dev/null || echo 0)"
if [ "${sched:-0}" -ge 1 ]; then
    _ok "the timer carries at least one schedule directive ($sched)"
else
    _bad "the timer carries a schedule" "no recognised schedule directive"
fi

# --- 4. the interval reaches the rendered unit ------------------------------
if grep -q 'OnUnitInactiveSec=24h' "$units/tillandsias-release-tier.timer" 2>/dev/null; then
    _ok "--interval reaches the unit"
else
    _bad "--interval reaches the unit" "24h not found in the rendered timer"
fi

# --- 5. NEGATIVE CONTROL: no placeholder survives rendering -----------------
# PREMISE FIRST: grep -l over files that do not exist prints nothing, which is
# indistinguishable from "no placeholders survived". On the first run of this
# fixture the render had failed entirely and this arm reported GREEN — an
# absence read as a clean result, which is the shape the whole suite is about.
if [ ! -f "$units/tillandsias-release-tier.service" ] \
   || [ ! -f "$units/tillandsias-release-tier.timer" ]; then
    _bad "no placeholder survives the render" \
         "cannot tell: the units were never rendered, so there was nothing to search"
else
    left="$(grep -l '@[A-Z]*@' "$units/tillandsias-release-tier.service" "$units/tillandsias-release-tier.timer" 2>/dev/null || true)"
    if [ -z "$left" ]; then
        _ok "no placeholder survives the render"
    else
        _bad "no placeholder survives the render" "placeholders left in: $left"
    fi
fi
rm -rf "$sandbox"

# --- 6. NEGATIVE CONTROL: a template with an UNKNOWN placeholder is refused --
# The drift case the guard exists for: a template gains a token the installer
# does not substitute. Without this the installer would write a unit systemd
# accepts and then behaves oddly under.
drift="$(mktemp -d)"
cp -r "$ROOT/packaging" "$drift/packaging"
cp -r "$ROOT/scripts" "$drift/scripts"
printf '\n# @NOSUCHTOKEN@\n' >> "$drift/packaging/systemd/user/tillandsias-release-tier.timer.in"
dv="$(XDG_CONFIG_HOME="$drift/cfg" "$drift/scripts/install-release-tier-timer.sh" 2>&1 | tail -1)"
case "$dv" in
    fail:install:unsubstituted-placeholder)
        _ok "an unsubstituted placeholder is refused, and the unit is not left behind" ;;
    *)
        _bad "an unsubstituted placeholder is refused" "got: $dv" ;;
esac
if [ -f "$drift/cfg/systemd/user/tillandsias-release-tier.timer" ]; then
    _bad "a refused render leaves no unit behind" "the timer file survived the refusal"
else
    _ok "a refused render leaves no unit behind"
fi
rm -rf "$drift"

# --- 7. NEGATIVE CONTROL: this fixture armed nothing on THIS host ------------
# The assertion the regime note promises. If the sandbox ever leaked, this is
# the arm that says so, and it is cheap enough to have no excuse for omitting.
if systemctl --user list-unit-files 2>/dev/null | grep -q 'tillandsias-release-tier'; then
    _bad "the fixture armed nothing on this host" \
         "tillandsias-release-tier is now known to the real user session — the sandbox leaked"
else
    _ok "the fixture armed nothing on this host"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
    printf 'ok:release-tier-timer-render:%d\n' "$pass"
    exit 0
fi
printf 'fail:release-tier-timer-render: %d passed, %d failed\n' "$pass" "$fail"
exit 1
