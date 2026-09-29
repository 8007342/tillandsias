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

# The uninstaller's macOS block reads two roots: a seamed /Applications and
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
# MATCHER-AGNOSTIC (1231-cbie). Was `grep -q 'pkill -TERM -f tillandsias-tray'`,
# which pinned the spelling rather than the property: narrowing `-f` to `-x`
# made this fail with "block-does-not-stop-the-running-tray" about a block that
# still stops the tray. The failure message named a property that still held,
# which is how a correct change gets "fixed" back into a defect.
printf '%s' "$BLOCK" | grep -qE 'pkill -TERM( -[a-zA-Z])? (tillandsias-tray|"[$]_tray")' || fail "block-does-not-stop-the-running-tray"
printf '%s' "$BLOCK" | grep -qF 'TILLANDSIAS_UNINSTALL_TRAY_PROC:-tillandsias-tray}' || fail "tray-seam-default-is-not-the-tray"

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

# 1401-p3k7: the system dir is a seam now; point it at the sandbox. The block
# must default to /Applications, and the run must never see the default: a
# sed rewrite that silently stopped matching would have run the real sweep.
printf '%s' "$BLOCK" | grep -qF 'TILLANDSIAS_UNINSTALL_APPS_DIR:-/Applications}' || fail "apps-seam-default-is-not-system-applications"
printf '%s\n' "$BLOCK" > "$TMP/block.sh"
export TILLANDSIAS_UNINSTALL_APPS_DIR="$FAKE_SYS" TILLANDSIAS_UNINSTALL_TRAY_PROC="nonce-tray-1401"

# ORDER 1365-tjav. THE BLOCK IS EXECUTED, and it stops the tray with
# pgrep/pkill. The sandbox above scopes FILESYSTEM paths only: a fake HOME and
# a rewritten /Applications do not scope the process table. Before this, every
# run sent real signals (four per gate, pre-1401 at the operator's own tray;
# since 1401-p3k7 at a nonce name, which is harmless only by luck of naming).
# The process commands now resolve to shims that RECORD and never signal, and
# PROC-SCOPE below proves they were intercepted.
#
# MEASURED 2026-09-29 (lenovinha): on the tree as filed, the stop sits behind
# `if [[ "$IS_MACOS" == true ]]`, and IS_MACOS is set BEFORE the extracted
# block, so inside this fixture it was unset and the stop never ran on any
# host. The signals stopped by accident, and the stop had NO behavioural
# coverage here. IS_MACOS=true now drives that path deliberately, under the
# shims, so the stop is exercised and provably cannot reach the process table. The textual assertion above
# (the tray is stopped before its bundle is deleted) stays: that property was
# found live on 2026-08-30 and is not what was wrong.
PROCSHIM="$TMP/procshim"; mkdir -p "$PROCSHIM"
for c in pgrep pkill killall; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/proc-calls"\n[ "%s" = pgrep ] && exit 0\nexit 0\n' "$c" "$TMP" "$c" > "$PROCSHIM/$c"
  chmod +x "$PROCSHIM/$c"
done
: > "$TMP/proc-calls"
IS_MACOS=true HOME="$FAKE_HOME" PATH="$PROCSHIM:$PATH" bash "$TMP/block.sh" >/dev/null 2>&1 || fail "block-exited-nonzero"
# PROC-SCOPE: the block's tray stop reached the shims (so nothing reached the
# process table), and it targeted only the nonce.
proc_scoped() {   # <calls file>
  grep -qE '^pkill -TERM' "$1" && grep -qE '^pkill -KILL' "$1" \
    && ! grep -vE 'nonce-tray-1401' "$1" | grep -q .
}
proc_scoped "$TMP/proc-calls" || fail "process-commands-escaped-the-sandbox($(tr '\n' ';' < "$TMP/proc-calls"))"
# NEGATIVE CONTROL: without the shims, the same arm must RED, or it passes
# vacuously. Safe to run only BECAUSE the tray seam names a nonce: the real
# pkill it reaches matches no process.
: > "$TMP/proc-calls-unshimmed"
IS_MACOS=true HOME="$FAKE_HOME" bash "$TMP/block.sh" >/dev/null 2>&1 || true
proc_scoped "$TMP/proc-calls-unshimmed" && fail "proc-scope-arm-passes-without-its-shims"

[ -e "$FAKE_SYS/Tillandsias.app" ]              && fail "system-app-survived"
[ -e "$FAKE_SYS/Tillandsias.app.bak" ]          && fail "system-bak-survived"
[ -e "$FAKE_HOME/Applications/Tillandsias.app" ]     && fail "home-app-survived"
[ -e "$FAKE_HOME/Applications/Tillandsias.app.bak" ] && fail "home-bak-survived"
[ -e "$FAKE_HOME/Library/LaunchAgents/com.tillandsias.tray.plist" ] && fail "launchagent-survived"

# An absent dir must not make the sweep fail — a user who never had the
# fallback dir (this host: $HOME/Applications does not exist) must still
# uninstall cleanly.
rm -rf "$FAKE_HOME/Applications"
IS_MACOS=true HOME="$FAKE_HOME" PATH="$PROCSHIM:$PATH" bash "$TMP/block.sh" >/dev/null 2>&1 || fail "absent-dir-made-the-sweep-fail"

if [ "$fails" -gt 0 ]; then
  echo "FAIL:uninstall-sweeps-both-app-dirs:$fails" >&2
  exit 1
fi
echo "ok:uninstall-sweeps-both-app-dirs"
exit 0
