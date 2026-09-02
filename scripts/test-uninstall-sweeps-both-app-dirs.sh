#!/usr/bin/env bash
# Fixture for the macOS uninstall sweep
# (plan/issues/macos-uninstall-misses-the-default-install-dir-2026-08-30.md).
#
# THE DEFECT THIS PINS: install-macos.sh prefers /Applications and falls back
# to $HOME/Applications only when /Applications is not writable. uninstall.sh
# used to remove ONLY the $HOME path, so on the DEFAULT target — an admin
# account, i.e. most personal Macs — uninstall left the app installed while
# removing the LaunchAgent beside it. Worse than a no-op.
#
# WHY THIS FIXTURE IS PLATFORM-INDEPENDENT, deliberately: the defect was
# darwin-only DETECTABLE, which is why it survived. Asserting the sweep by
# pointing the uninstaller at a fake HOME and a fake /Applications means every
# lane can catch a regression, not just the one host that can install for real.
# It never touches a real /Applications.
#
# Grammar (one line on stdout):
#   ok:uninstall-sweeps-both-app-dirs | FAIL:<what>
# Exit 0 exactly on ok.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNINSTALL="$ROOT/scripts/uninstall.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/uninstall-sweep.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fails=0

fail() { echo "FAIL:$1" >&2; fails=$((fails + 1)); }

# The uninstaller's macOS block reads two roots: a literal /Applications and
# $HOME/Applications. Extract just that block and exercise it against fakes —
# running the whole uninstaller would touch the real machine.
BLOCK="$(sed -n '/── macOS desktop cleanup/,/^rm -f "\$HOME\/Library\/LaunchAgents/p' "$UNINSTALL")"
if [ -z "$BLOCK" ]; then
  echo "FAIL:macos-cleanup-block-not-found" >&2
  echo "  The fixture locates the block by its '── macOS desktop cleanup' banner." >&2
  echo "  If that banner was renamed, update this fixture — do not delete the assertion." >&2
  exit 1
fi

# Both candidate dirs must be named. A sweep that lost one would still pass a
# test that only stubbed the other, which is exactly how the original defect
# hid, so assert the intent textually as well as behaviourally.
printf '%s' "$BLOCK" | grep -q '/Applications' || fail "block-does-not-name-system-applications"
printf '%s' "$BLOCK" | grep -q 'HOME/Applications' || fail "block-does-not-name-home-applications"
printf '%s' "$BLOCK" | grep -q 'Tillandsias.app.bak' || fail "block-does-not-remove-the-bak-sibling"
# The tray must be STOPPED before its bundle is deleted. Asserted textually,
# never behaviourally: a fixture that ran `pkill -f tillandsias-tray` would
# kill the real tray on a developer's machine. Found live 2026-08-30 — the
# uninstaller removed the bundle and left the process running from it,
# still owning the VM.
printf '%s' "$BLOCK" | grep -q 'pkill -TERM -f tillandsias-tray' || fail "block-does-not-stop-the-running-tray"

# Behavioural: stub BOTH dirs with an app and its .bak, run the block with
# /Applications and $HOME redirected into the sandbox, assert both are empty.
FAKE_SYS="$TMP/Applications"
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_SYS" "$FAKE_HOME/Applications" "$FAKE_HOME/Library/LaunchAgents"
for d in "$FAKE_SYS" "$FAKE_HOME/Applications"; do
  mkdir -p "$d/Tillandsias.app/Contents/MacOS" "$d/Tillandsias.app.bak/Contents/MacOS"
  echo stub > "$d/Tillandsias.app/Contents/MacOS/tillandsias-tray"
  echo stub > "$d/Tillandsias.app.bak/Contents/MacOS/tillandsias-tray"
done
echo stub > "$FAKE_HOME/Library/LaunchAgents/com.tillandsias.tray.plist"

# Rewrite the literal system path onto the sandbox, then run with a fake HOME.
printf '%s\n' "$BLOCK" | sed "s#\"/Applications\"#\"$FAKE_SYS\"#g" > "$TMP/block.sh"
grep -q "$FAKE_SYS" "$TMP/block.sh" || fail "sandbox-redirect-did-not-apply"
HOME="$FAKE_HOME" bash "$TMP/block.sh" >/dev/null 2>&1 || fail "block-exited-nonzero"

[ -e "$FAKE_SYS/Tillandsias.app" ]              && fail "system-app-survived"
[ -e "$FAKE_SYS/Tillandsias.app.bak" ]          && fail "system-bak-survived"
[ -e "$FAKE_HOME/Applications/Tillandsias.app" ]     && fail "home-app-survived"
[ -e "$FAKE_HOME/Applications/Tillandsias.app.bak" ] && fail "home-bak-survived"
[ -e "$FAKE_HOME/Library/LaunchAgents/com.tillandsias.tray.plist" ] && fail "launchagent-survived"

# An absent dir must not make the sweep fail — a user who never had the
# fallback dir (this host: $HOME/Applications does not exist) must still
# uninstall cleanly.
rm -rf "$FAKE_HOME/Applications"
HOME="$FAKE_HOME" bash "$TMP/block.sh" >/dev/null 2>&1 || fail "absent-dir-made-the-sweep-fail"

if [ "$fails" -gt 0 ]; then
  echo "FAIL:uninstall-sweeps-both-app-dirs:$fails" >&2
  exit 1
fi
echo "ok:uninstall-sweeps-both-app-dirs"
exit 0
