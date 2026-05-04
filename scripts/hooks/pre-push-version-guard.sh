#!/usr/bin/env bash
# pre-push-version-guard.sh — Guard against invalid VERSION modifications
# @trace spec:versioning
#
# Purpose: Prevent pushes that modify VERSION file to non-main branches or
# warn users before pushing VERSION changes without spec-cheatsheet binding.
#
# This hook runs during `git push` and checks:
# 1. If VERSION was modified, only allow push to main branch
# 2. If VERSION was modified, emit advisory about spec-cheatsheet binding
#
# Philosophy: Loose guard. The hook can be bypassed with --no-verify, but
# emits warnings to guide users toward correct workflow.
#
# Usage:
#   Installed as .git/hooks/pre-push (via scripts/install-hooks.sh)
#   Or run manually: bash scripts/hooks/pre-push-version-guard.sh <remote> <url>

set -uo pipefail

# Git pre-push receives remote name and URL as arguments
# We don't need them here, but they're passed by git
# remote="${1:-}"
# url="${2:-}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
VERSION_FILE="$REPO_ROOT/VERSION"

# Determine push target branch
branch="$(git symbolic-ref --short HEAD 2>/dev/null)" || {
    # Detached HEAD — allow push (rare)
    exit 0
}

# Check if VERSION was modified in commits being pushed
# Compare current VERSION file against main branch
main_version="$(git show main:VERSION 2>/dev/null)" || {
    # main branch doesn't exist yet (initial setup) — allow
    exit 0
}
current_version="$(cat "$VERSION_FILE" 2>/dev/null)" || {
    # VERSION file missing — let other checks catch this
    exit 0
}

# If VERSION is different from main, it means current branch modified it
if [[ "$main_version" != "$current_version" ]]; then
    # Check if we're pushing to main
    if [[ "$branch" != "main" ]]; then
        echo "" >&2
        echo "⚠ Pre-push guard: VERSION modified on non-main branch '$branch'" >&2
        echo "" >&2
        echo "  Current VERSION: $current_version" >&2
        echo "  Main VERSION:    $main_version" >&2
        echo "" >&2
        echo "  VERSION is typically updated only on the main branch after /opsx:archive." >&2
        echo "  If you intended to bump VERSION, either:" >&2
        echo "    1. Push to main (allowed)" >&2
        echo "    2. Revert VERSION changes to match main" >&2
        echo "    3. Use 'git push --no-verify' to bypass this check (not recommended)" >&2
        echo "" >&2
        exit 1
    fi

    # We're pushing to main with VERSION change — emit advisory
    echo "" >&2
    echo "ℹ Pre-push notice: VERSION was modified on main branch" >&2
    echo "  Before releasing, ensure:" >&2
    echo "    1. All specs have @trace annotations in code" >&2
    echo "    2. All specs reference cheatsheets via 'Sources of Truth'" >&2
    echo "    3. Run: bash scripts/validate-spec-cheatsheet-binding.sh --threshold 90" >&2
    echo "" >&2
fi

# Remind user to run local CI checks
echo "" >&2
echo "ℹ Reminder: Have you run local CI checks?" >&2
echo "  scripts/local-ci.sh              # Full suite (includes litmus tests)" >&2
echo "  scripts/local-ci.sh --fast       # Quick checks only" >&2
echo "" >&2

exit 0
