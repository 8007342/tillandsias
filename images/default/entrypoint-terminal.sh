#!/usr/bin/env bash
# entrypoint-terminal.sh — Maintenance terminal entrypoint.
#
# Lifecycle: source common -> find project -> welcome banner -> exec fish
#
# No agent install, no OpenSpec. Just a properly configured shell.
# Secrets: gh credentials, git config only. No agent secrets.

source /usr/local/lib/tillandsias/lib-common.sh

# ── Find project directory ──────────────────────────────────
find_project_dir
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"

# ── Welcome banner ──────────────────────────────────────────
# Use the dedicated welcome script if available (shows mount info, tips).
WELCOME_SCRIPT="/usr/local/share/tillandsias/forge-welcome.sh"
if [ -x "$WELCOME_SCRIPT" ]; then
    "$WELCOME_SCRIPT" || true
else
    show_banner "terminal"
fi

# ── Launch shell ────────────────────────────────────────────
if command -v fish &>/dev/null; then
    exec fish
else
    exec bash
fi
