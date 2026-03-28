# fix-entrypoint-agent-launch

Fix forge container entrypoint to properly handle agent selection after the
default agent was switched from opencode to claude. The entrypoint was still
unconditionally defining opencode paths and the `opencode/opencode` doubled
path caused "cannot execute: required file not found" errors.

## Problem

The entrypoint defines `OC_BIN="$CACHE/opencode/opencode"` unconditionally
on every launch, even when `TILLANDSIAS_AGENT=claude`. The tar extraction
for opencode creates a doubled directory path (`opencode/opencode`). When the
entrypoint falls through to the wildcard case, it tries to exec this path
which fails.

## Fix

- Move opencode variable definitions inside the opencode-specific branch
- Fix the opencode binary path to avoid the doubled directory
- Ensure the claude path is clean and self-contained
- Keep opencode support functional when explicitly selected
