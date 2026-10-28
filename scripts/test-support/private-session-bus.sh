# shellcheck shell=bash
# ORDER 1903-djsq — A KEYRING FIXTURE NEVER REACHES THE OPERATOR'S SESSION BUS.
#
# Sourced at the top of every gate-reachable fixture that drives the credential
# guard, busctl, secret-tool or gh. It points DBUS_SESSION_BUS_ADDRESS at a
# socket path under a directory that cannot exist, so every D-Bus client the
# fixture starts (a stub's fall-through to the real busctl, gh's go-keyring,
# libsecret's secret-tool) fails at once with ENOENT instead of opening the
# operator's gnome-keyring-daemon.
#
# WHY. gnome-keyring-daemon 50.0 aborts in invoke_get_property_in_idle_cb
# (1265-8qr6) and D-Bus re-activates it LOCKED; gh then blocks and every push
# fails until the operator unlocks. That abort was seen during full gates on
# macuahuitl (2026-10-25 20:36, 20:51; 2026-10-26 02:01 PDT) and lenovinha
# (2026-10-26 01:03 PDT). A fixture tests the guard's LOGIC; it has no
# business making a real call on the real store, and a timeout(1) in a
# fixture that kills a real client mid-call is exactly the crash input.
#
# A dead address, not dbus-run-session: no daemon or temp dir to reap, it
# works on macOS (no dbus at all), and "no bus answered" is the hermetic
# regime these fixtures already stub. XDG_RUNTIME_DIR is left alone because
# sd-bus, libdbus, gio and godbus all honour DBUS_SESSION_BUS_ADDRESS first.
#
# Guarded by scripts/test-keyring-fixtures-use-a-private-bus.sh.
export DBUS_SESSION_BUS_ADDRESS="unix:path=/nonexistent/tillandsias-private-bus/no-bus"
