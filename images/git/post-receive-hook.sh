#!/bin/bash
# @trace spec:git-mirror-service
# Template post-receive hook for git mirrors managed by Tillandsias.
# Installed into each mirror's hooks/post-receive directory.
# Pushes to the configured origin remote after receiving from a forge container.
# Always exits 0 — never blocks the forge's push even if the remote push fails.

REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"

if [ -z "$REMOTE_URL" ]; then
    echo "[git-mirror] No remote configured, skipping push"
    exit 0
fi

if OUTPUT="$(git push --mirror origin 2>&1)"; then
    echo "[git-mirror] Push to origin: success"
else
    echo "[git-mirror] Push to origin: FAILED: $OUTPUT"
fi

exit 0
