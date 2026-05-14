#!/usr/bin/env bash
set -euo pipefail

ARGS=(
    "$@"
    "--disable-crash-reporter"
    "--disable-breakpad"
    "--disable-sync"
)

if command -v chromium >/dev/null 2>&1; then
    exec chromium "${ARGS[@]}" 2>/dev/null || true
fi

if command -v chromium-browser >/dev/null 2>&1; then
    exec chromium-browser "${ARGS[@]}" 2>/dev/null || true
fi

echo "chromium framework launcher: no chromium binary found" >&2
exit 127
