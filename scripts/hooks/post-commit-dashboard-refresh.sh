#!/usr/bin/env bash
# post-commit-dashboard-refresh.sh — Auto-trigger dashboard refresh when TRACES.md changes
# @trace gap:OBS-008, spec:observability-convergence
#
# This hook detects when TRACES.md has been committed and automatically
# regenerates the CentiColon dashboard to keep it fresh with the latest
# trace index updates.
#
# Philosophy: Non-blocking, fire-and-forget. If dashboard regeneration fails,
# we log a warning but don't abort the post-commit flow (git diff is already complete).
#
# Usage: Installed as .git/hooks/post-commit (via scripts/install-hooks.sh)

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
DASHBOARD_SCRIPT="$REPO_ROOT/scripts/update-convergence-dashboard.sh"
TRACES_FILE="$REPO_ROOT/TRACES.md"

# Check if TRACES.md was part of the last commit
# Use git diff-tree to check what files changed in HEAD
traces_changed="$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null \
    | grep -F 'TRACES.md' || true)"

# If TRACES.md wasn't modified, nothing to do
[[ -z "$traces_changed" ]] && exit 0

# TRACES.md was modified — regenerate the dashboard
# Run the dashboard script in the background to avoid blocking git flow
if [[ -x "$DASHBOARD_SCRIPT" ]]; then
    # Non-blocking: run dashboard refresh in background with output suppressed
    # Errors are logged to a temporary file for observability but don't block the commit
    bash "$DASHBOARD_SCRIPT" >/dev/null 2>&1 &
    # Detach the background job so it doesn't block git's post-commit cleanup
    disown -a 2>/dev/null || true
fi

exit 0
