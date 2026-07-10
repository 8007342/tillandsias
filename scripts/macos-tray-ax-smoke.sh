#!/usr/bin/env bash
# =============================================================================
# Tillandsias — macOS tray AX (Accessibility) smoke harness
#
# Deterministic, scriptable GUI smoke for the macOS tray, built entirely on
# macOS built-ins (no third-party install):
#
#   - osascript / System Events (Accessibility API) — enumerate + click the
#     status-menu items the autonomous build skill otherwise cannot see.
#   - screencapture + sips — pixel capture of a menu-bar region (best-effort;
#     notification banners can occlude it — AX enumeration is authoritative).
#   - screen -X hardcopy — dump a PTY/`screen` device-flow surface (e.g. the
#     GitHub-login attach terminal) to text so a finding can assert content.
#
# This codifies the operator-attended 2026-06-21 interactive session into a
# repeatable harness so future macOS builds can verify tray icon + menu
# interaction without a human. See
#   plan/issues/macos-tray-ui-automation-framework-2026-06-21.md
#
# Requirements: the controlling process (Terminal/osascript) must hold
# Accessibility permission (System Settings → Privacy & Security →
# Accessibility). Grant once per host; persists.
#
# Usage:
#   scripts/macos-tray-ax-smoke.sh menu                 # enumerate top-level menu items
#   scripts/macos-tray-ax-smoke.sh assert-item <substr> # exit 0 iff a menu item title contains <substr>
#   scripts/macos-tray-ax-smoke.sh click <substr>       # open menu and click first item containing <substr>
#   scripts/macos-tray-ax-smoke.sh icon-present         # exit 0 iff the status item (AX) exists
#   scripts/macos-tray-ax-smoke.sh screenshot <out.png> # capture menu-bar strip (best-effort)
#   scripts/macos-tray-ax-smoke.sh pty-dump <out.txt>   # hardcopy the active `screen` PTY surface
#
# @trace spec:macos-native-tray, plan/issues/macos-tray-ui-automation-framework-2026-06-21.md
# =============================================================================

set -euo pipefail

PROC="${TILLANDSIAS_TRAY_PROCESS:-tillandsias-tray}"

die() { printf 'macos-tray-ax-smoke: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "must run on macOS"

# Fail loud if the tray process is not running — silence must never look like success.
require_proc() {
  pgrep -x "$PROC" >/dev/null 2>&1 || die "tray process '$PROC' not running"
}

# Enumerate the status-menu top-level item titles, one per line.
# Separators (no title) are emitted as the literal token (sep).
ax_menu() {
  require_proc
  osascript <<OSA 2>&1
tell application "System Events"
  tell process "$PROC"
    set sm to menu bar item 1 of menu bar 1
    click sm
    delay 0.4
    set out to ""
    repeat with mi in (menu items of menu 1 of sm)
      set t to "(sep)"
      try
        set t to title of mi
      end try
      set out to out & t & linefeed
    end repeat
    key code 53
    return out
  end tell
end tell
OSA
}

# Click the first menu item whose title contains the given substring.
ax_click() {
  local needle="$1"
  require_proc
  osascript <<OSA 2>&1
tell application "System Events"
  tell process "$PROC"
    set sm to menu bar item 1 of menu bar 1
    click sm
    delay 0.4
    set hit to false
    repeat with mi in (menu items of menu 1 of sm)
      set t to ""
      try
        set t to title of mi
      end try
      if t contains "$needle" then
        click mi
        set hit to true
        exit repeat
      end if
    end repeat
    if hit is false then
      key code 53
      error "no menu item containing: $needle"
    end if
    return "clicked: " & "$needle"
  end tell
end tell
OSA
}

# Exit 0 iff the AX status item exists (icon is rendered in the menu bar).
ax_icon_present() {
  require_proc
  local n
  n=$(osascript -e "tell application \"System Events\" to tell process \"$PROC\" to count of menu bar items of menu bar 1" 2>/dev/null || echo 0)
  [[ "${n:-0}" -ge 1 ]] || die "no status item in menu bar (icon not rendered)"
  echo "ok:status-item-present"
}

# Best-effort menu-bar screenshot. AX enumeration is authoritative; a
# notification banner can occlude the icon here, so this is supplementary.
shoot() {
  local out="$1"
  screencapture -x "$out"
  echo "captured: $out"
}

# Dump the active `screen` PTY surface (e.g. the GitHub-login attach terminal).
pty_dump() {
  local out="$1"
  local sid="${2:-}"
  # F-F (order 269): resolve the session robustly. `screen -ls` exits
  # non-zero when a session is Attached AND prints tab-indented lines like
  # "\t86884.ttys002.host\t(Attached)"; the old `[0-9]+\.[^ \t]+` + head
  # could yield an empty sid that then became `screen -S "" -X hardcopy`,
  # whose failure ("No screen session found") looked like "no session"
  # even though one was listed. Take an explicit session as $2, else match
  # the full pid.tty[.host] token on any listing line (attached or
  # detached), and fail loud with the raw listing if none is found.
  if [[ -z "$sid" ]]; then
    sid=$(screen -ls 2>/dev/null | grep -oE '[0-9]+\.[A-Za-z0-9._-]+' | head -1 || true)
  fi
  if [[ -z "$sid" ]]; then
    die "no active screen session to hardcopy; screen -ls said: $(screen -ls 2>&1 | tr '\n' ' ')"
  fi
  screen -S "$sid" -X hardcopy "$out" || die "hardcopy failed for session '$sid'"
  sleep 0.5
  [[ -s "$out" ]] || die "hardcopy produced no output for session '$sid'"
  echo "dumped session $sid -> $out"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  menu)         ax_menu ;;
  assert-item)  [[ $# -ge 1 ]] || die "assert-item needs <substr>"; ax_menu | grep -qF "$1" && echo "ok:item-present:$1" || die "menu item not found: $1" ;;
  click)        [[ $# -ge 1 ]] || die "click needs <substr>"; ax_click "$1" ;;
  icon-present) ax_icon_present ;;
  screenshot)   [[ $# -ge 1 ]] || die "screenshot needs <out.png>"; shoot "$1" ;;
  pty-dump)     [[ $# -ge 1 ]] || die "pty-dump needs <out.txt> [session]"; pty_dump "$1" "${2:-}" ;;
  *) die "unknown command: '${cmd:-}' (menu|assert-item|click|icon-present|screenshot|pty-dump)" ;;
esac
