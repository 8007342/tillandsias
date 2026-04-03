#!/usr/bin/env bash
# entrypoint-terminal.sh — Maintenance terminal entrypoint.
#
# Lifecycle: source common -> install OpenSpec -> find project ->
#            openspec init -> welcome banner -> exec fish
#
# Secrets: gh credentials, git config only. No agent secrets.

source /usr/local/lib/tillandsias/lib-common.sh

# @trace spec:forge-welcome
trace_lifecycle "entrypoint" "terminal starting"

# ── OpenSpec (available in maintenance terminals too) ───────
# @trace spec:forge-shell-tools
install_openspec
OS_BIN="$CACHE/openspec/bin/openspec"

# ── Find project directory ──────────────────────────────────
find_project_dir
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── OpenSpec init (every launch, silent) ────────────────────
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ]; then
    "$OS_BIN" init >/dev/null 2>&1 || true
fi

# ── Welcome banner ──────────────────────────────────────────
# Use the dedicated welcome script if available (shows mount info, tips).
WELCOME_SCRIPT="/usr/local/share/tillandsias/forge-welcome.sh"
if [ -x "$WELCOME_SCRIPT" ]; then
    "$WELCOME_SCRIPT" || true
else
    show_banner "terminal"
fi

# Prevent fish's config.fish from showing the welcome banner again.
export TILLANDSIAS_WELCOME_SHOWN=1

# ── Launch shell ────────────────────────────────────────────
echo "[lifecycle] entrypoint | terminal launching" >&2
if command -v fish &>/dev/null; then
    trace_lifecycle "exec" "launching fish"
    exec fish
else
    exec bash
fi
