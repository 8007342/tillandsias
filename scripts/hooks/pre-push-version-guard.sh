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
# remote="${1:-}"
# url="${2:-}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
VERSION_FILE="$REPO_ROOT/VERSION"

# Determine push target branch
branch="$(git symbolic-ref --short HEAD 2>/dev/null)" || {
    # Detached HEAD — allow push (rare)
    exit 0
}

# DOES THIS PUSH MODIFY VERSION?
#
# The original test was `VERSION != main:VERSION`, which is not the same
# question and made the guard unusable. Between releases, linux-next legitimately
# carries a VERSION ahead of main — main only catches up when a release lands —
# so that test refused EVERY linux-next push. It went unnoticed for months only
# because .git/hooks/ was empty and the hook never ran; the day it was installed
# (2026-08-03) it blocked the first push it saw, on commits that never touched
# VERSION.
#
# That failure mode is worse than no guard: a check that must be bypassed on
# every push trains `--no-verify`, and `--no-verify` also skips the local gate
# that is now the trunk's only protection. A guard has to be right to be obeyed.
#
# The real question is whether the COMMITS BEING PUSHED change VERSION. Git hands
# the ref list on stdin as "<local ref> <local sha> <remote ref> <remote sha>";
# when stdin is unavailable we fall back to @{upstream}..HEAD, and if neither is
# available we allow rather than guess.
version_touched=false
ranges=""
if [[ ! -t 0 ]]; then
    while read -r _lref lsha _rref rsha; do
        [[ -n "${lsha:-}" ]] || continue
        # deletion
        [[ "$lsha" =~ ^0+$ ]] && continue
        if [[ "${rsha:-}" =~ ^0+$ || -z "${rsha:-}" ]]; then
            # New remote branch: compare against its merge-base with origin/HEAD
            base="$(git merge-base "$lsha" origin/main 2>/dev/null)" || base=""
            [[ -n "$base" ]] && ranges+="$base..$lsha "
        else
            ranges+="$rsha..$lsha "
        fi
    done
fi
if [[ -z "$ranges" ]]; then
    upstream="$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" || upstream=""
    [[ -n "$upstream" ]] && ranges="$upstream..HEAD"
fi
for r in $ranges; do
    if git diff --name-only "$r" 2>/dev/null | grep -qx "VERSION"; then
        version_touched=true
        break
    fi
done

current_version="$(cat "$VERSION_FILE" 2>/dev/null)" || exit 0
main_version="$(git show origin/main:VERSION 2>/dev/null || git show main:VERSION 2>/dev/null)" || main_version=""

if [[ "$version_touched" == true ]]; then
    # Check if we're pushing to main
    if [[ "$branch" != "main" ]]; then
        echo "" >&2
        echo "⚠ Pre-push guard: VERSION modified on non-main branch '$branch'" >&2
        echo "" >&2
        echo "  Current VERSION: $current_version" >&2
        echo "  Main VERSION:    $main_version" >&2
        echo "" >&2
        echo "  The commits being pushed CHANGE VERSION. That belongs on main," >&2
        echo "  which is where a release bump lands." >&2
        echo "  If you intended to bump VERSION, either:" >&2
        echo "    1. Push to main (allowed)" >&2
        echo "    2. Drop the VERSION change from these commits" >&2
        echo "    3. Use 'git push --no-verify' to bypass (also skips the local gate)" >&2
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

# No "have you run local CI?" reminder here any more. Asking the operator whether
# they ran the checks IS the prompt-dependent enforcement this project ruled out,
# and it was never load-bearing — a reminder cannot fail a push. That question is
# now ANSWERED, not asked, by pre-push-local-gate.sh, which verifies the gate
# stamp and refuses when ./build.sh --check has not run against this tree.

exit 0
