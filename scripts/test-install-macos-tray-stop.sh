#!/usr/bin/env bash
# @trace order:1244-9dx3, order:1426-cb6g, spec:macos-tray-build-and-release
#
# test-install-macos-tray-stop.sh — install-macos.sh stops a running tray by
# the routes that DRAIN its VM, and never SIGKILLs it before a drain can finish.
#
# MEASURED on the v56.9.27.1 smoke (2026-09-27): `tell application
# "tillandsias-tray" to quit` (the EXECUTABLE name; AppleScript resolves bundle
# names/ids) left a running tray alive for 30 s, so every reinstall fell through
# to `pkill -TERM` — which the tray did not handle, so the VM stop path never
# ran and the per-launch vm-swap.img survived. The tray now drains on the quit
# Apple event and on SIGTERM; this fixture pins the installer side:
#   1. the graceful stage addresses the app by BUNDLE ID;
#   2. that bundle id is the one the bundle actually declares (drift guard);
#   3. the executable-name form is gone;
#   4. no SIGKILL can happen before the tray's 60 s drain bound has elapsed.
# Static by construction: the stage is inline in an installer that downloads
# and swaps /Applications, and this fixture must never touch /Applications.
#
# Grammar: ok:install-macos-tray-stop:<n> | FAIL:install-macos-tray-stop:<n>
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INST="$ROOT/scripts/install-macos.sh"
PLIST="$ROOT/crates/tillandsias-macos-tray/assets/Info.plist.template"
HOST="$ROOT/crates/tillandsias-macos-tray/src/action_host.rs"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

bid="$(awk '/<key>CFBundleIdentifier<\/key>/ { getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit }' "$PLIST")"
[ -n "$bid" ] && ok "the bundle declares CFBundleIdentifier=$bid" || bad "no CFBundleIdentifier in $PLIST"

if grep -qF "tell application id \"$bid\" to quit" "$INST"; then
    ok "the graceful stage addresses the tray by its bundle id"
else
    bad "the graceful stage does not address the app by bundle id \"$bid\""
fi

if grep -qF 'tell application "tillandsias-tray"' "$INST"; then
    bad "the executable-name form is still present (it never reaches a running tray)"
else
    ok "the executable-name form is gone"
fi

drain="$(sed -n 's/^const VM_STOP_DRAIN: Duration = Duration::from_secs(\([0-9]*\));.*/\1/p' "$HOST")"
waits="$(grep -oE '_tray_wait [0-9]+' "$INST" | awk '{printf "%s%s", (n++ ? " " : ""), $2}')"
kill_line="$(grep -n -m1 'pkill -KILL -x tillandsias-tray' "$INST" | cut -d: -f1)"
if [ -z "$drain" ] || [ -z "$waits" ] || [ -z "$kill_line" ]; then
    bad "could not read the drain bound ($drain), the waits ($waits) or the SIGKILL line ($kill_line)"
else
    short=0
    for w in $waits; do [ "$w" -gt "$drain" ] || short=1; done
    [ "$short" -eq 0 ] \
        && ok "every wait ($waits s) exceeds the tray's ${drain}s drain bound before SIGKILL" \
        || bad "a wait ($waits s) does not exceed the ${drain}s drain: SIGKILL could cut a drain short"
fi

if [ "$fail" -gt 0 ]; then
    echo "FAIL:install-macos-tray-stop:$fail"
    exit 1
fi
echo "ok:install-macos-tray-stop:$pass"
exit 0
