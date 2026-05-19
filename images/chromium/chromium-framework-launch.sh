#!/usr/bin/env bash
set -euo pipefail

# Chromium's setuid sandbox cannot launch inside our hardening (--cap-drop=ALL
# + --security-opt=no-new-privileges); the container exits 21 ("no usable
# sandbox") without --no-sandbox. The container itself remains locked down
# via userns, dropped caps, no-new-privileges, and per-process tmpfs mounts.
ARGS=(
    "$@"
    "--disable-crash-reporter"
    "--disable-breakpad"
    "--disable-sync"
    "--no-sandbox"
)

if command -v chromium >/dev/null 2>&1; then
    exec chromium "${ARGS[@]}"
fi

if command -v chromium-browser >/dev/null 2>&1; then
    exec chromium-browser "${ARGS[@]}"
fi

echo "chromium framework launcher: no chromium binary found" >&2
exit 127
