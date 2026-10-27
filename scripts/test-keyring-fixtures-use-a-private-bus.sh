#!/usr/bin/env bash
# ORDER 1903-djsq — no gate-reachable keyring fixture reaches the session bus it
# inherited.
#
# gnome-keyring-daemon aborted ("Bail out! gdbusconnection.c:4765
# invoke_get_property_in_idle_cb (error != NULL)") DURING full gates on
# macuahuitl (2026-10-25 20:36, 20:51; 2026-10-26 02:01 PDT) and lenovinha
# (2026-10-26 01:03 PDT) — the 1265-8qr6 shape. It restarts LOCKED, gh hangs,
# and every push fails until the operator unlocks. The fixtures below drive the
# credential guard with PATH-prefixed stubs, but PATH="$stub:$PATH" falls
# through to the real busctl/gh/secret-tool for anything not stubbed, and they
# inherited the operator's DBUS_SESSION_BUS_ADDRESS.
#
# METHOD. Start a SENTINEL dbus-daemon, watch it with dbus-monitor for
# NameOwnerChanged (one per connection that completes Hello), point
# DBUS_SESSION_BUS_ADDRESS at it, and run each fixture. A fixture that reaches
# whatever bus it inherited shows up as a connection on the sentinel; under the
# fix (scripts/test-support/private-session-bus.sh) it shows up as none. The
# operator's real bus is never touched by this script, because the fixtures'
# inherited address IS the sentinel.
#
# Arms:
#   0  population: every listed fixture exists, and the list is not empty.
#   1  control: a bare `busctl --user list` registers >= 1 connection on the
#      sentinel, so a zero below is the fixtures, not a deaf instrument.
#   2  each fixture: zero connections reached the sentinel.
#   3  static: each fixture sources private-session-bus.sh (the cheap form
#      that also holds on a host with no dbus-daemon).
#
# Exit 0 pass, 1 fail, 3 could-not-run (no dbus-daemon/dbus-monitor, e.g.
# macOS; arms 0 and 3 still run there and a failure in them is still exit 1).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FIXTURES=(
    scripts/test-check-credential-channel.sh
    scripts/test-credential-channel-survives-a-killed-probe.sh
    scripts/test-credential-cold-state-probe.sh
    scripts/test-credential-channel-names-a-locked-keyring.sh
    scripts/test-credential-channel-affordances.sh
    scripts/test-clear-vault-host-credentials.sh
    scripts/test-clear-vault-credentials-partial-is-nonzero.sh
    scripts/test-credential-verdict-script.sh
)

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# ── 0. population
if [ "${#FIXTURES[@]}" -gt 0 ]; then ok "population: ${#FIXTURES[@]} keyring fixtures listed"; else bad "population: the fixture list is empty"; fi
for f in "${FIXTURES[@]}"; do
    [ -f "$ROOT/$f" ] || bad "population: $f does not exist" "remove it from FIXTURES or restore it"
done

# ── 3. static
for f in "${FIXTURES[@]}"; do
    [ -f "$ROOT/$f" ] || continue
    if grep -qE '^[[:space:]]*(\.|source)[[:space:]].*test-support/private-session-bus\.sh' "$ROOT/$f"; then
        ok "static: $f sources private-session-bus.sh"
    else
        bad "static: $f does not source scripts/test-support/private-session-bus.sh" \
            "add near the top: . \"\$(dirname \"\$0\")/test-support/private-session-bus.sh\""
    fi
done

if ! command -v dbus-daemon >/dev/null 2>&1 || ! command -v dbus-monitor >/dev/null 2>&1 \
   || ! command -v busctl >/dev/null 2>&1; then
    printf 'pass=%d fail=%d\n' "$pass" "$fail"
    if [ "$fail" -gt 0 ]; then echo "violation:keyring-fixtures-use-a-private-bus"; exit 1; fi
    echo "skip:keyring-fixtures-use-a-private-bus:no-dbus-daemon (static arms passed)"
    exit 3
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/kfpb.XXXXXX")"
DPID="" MPID=""
cleanup() {
    [ -n "$MPID" ] && kill "$MPID" 2>/dev/null
    [ -n "$DPID" ] && kill "$DPID" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$W"
}
trap cleanup EXIT

dbus-daemon --session --nofork --nopidfile --address="unix:path=$W/sentinel" \
    --print-address=1 >"$W/addr" 2>"$W/daemon.err" </dev/null &
DPID=$!
i=0
while [ ! -s "$W/addr" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
SENTINEL="$(head -n 1 "$W/addr")"
if [ -z "$SENTINEL" ]; then
    bad "the sentinel dbus-daemon did not start" "$(cat "$W/daemon.err" 2>/dev/null)"
    printf 'pass=%d fail=%d\n' "$pass" "$fail"; echo "violation:keyring-fixtures-use-a-private-bus"; exit 1
fi
dbus-monitor --address "$SENTINEL" \
    "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged'" \
    >"$W/mon" 2>&1 </dev/null &
MPID=$!
i=0
while ! grep -q 'NameOwnerChanged' "$W/mon" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done

# Each completed connection emits NameOwnerChanged with a unique name gaining
# an owner. The monitor's own connection is counted once before any arm runs.
conns() { grep -c 'member=NameOwnerChanged' "$W/mon" 2>/dev/null || true; }
settle() { sleep 0.3; }
settle
base="$(conns)"

# ── 1. control
DBUS_SESSION_BUS_ADDRESS="$SENTINEL" busctl --user list --no-pager >/dev/null 2>&1
settle
now="$(conns)"
if [ "$now" -gt "$base" ]; then
    ok "control: a bare busctl --user list registers on the sentinel ($base -> $now)"
else
    bad "control: a bare busctl --user list did not register on the sentinel ($base -> $now)" \
        "the instrument is deaf; a zero below would mean nothing"
fi
base="$now"

# ── 2. each fixture
for f in "${FIXTURES[@]}"; do
    [ -f "$ROOT/$f" ] || continue
    ( cd "$ROOT" && DBUS_SESSION_BUS_ADDRESS="$SENTINEL" bash "$ROOT/$f" ) >"$W/out" 2>&1 </dev/null
    frc=$?
    settle
    now="$(conns)"
    if [ "$now" -eq "$base" ]; then
        ok "bus: $f made 0 bus events on the bus it inherited (its own rc=$frc; its gate step judges that)"
    else
        bad "bus: $f caused $((now - base)) NameOwnerChanged event(s) on the bus it inherited (a client connects and leaves = 2)" \
            "on an operator host that is the real session bus and gnome-keyring-daemon (1265-8qr6)"
    fi
    base="$now"
done

printf 'pass=%d fail=%d\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then echo "violation:keyring-fixtures-use-a-private-bus"; exit 1; fi
echo "ok:keyring-fixtures-use-a-private-bus:$pass"
