#!/bin/bash
# @trace spec:git-mirror-service
# Template post-receive hook for git mirrors managed by Tillandsias.
# Installed into each mirror's hooks/post-receive directory.
# Pushes to the configured origin remote after receiving from a forge container.
# Always exits 0 — never blocks the forge's push even if the remote push fails.
# DISTRO: Alpine 3.20 — bash installed explicitly via apk add bash.
#         Uses POSIX-compatible constructs only (no [[ ]], no arrays).

# @trace spec:podman-orchestration
# Per-container log directory mounted at /var/log/tillandsias/ (RW).
LOG_FILE="/var/log/tillandsias/git-push.log"
log_msg() {
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')"
    echo "$timestamp $1" >> "$LOG_FILE" 2>/dev/null
    echo "$1"
}

REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"

if [ -z "$REMOTE_URL" ]; then
    log_msg "[git-mirror] No remote configured, skipping push"
    exit 0
fi

if OUTPUT="$(git push --mirror origin 2>&1)"; then
    log_msg "[git-mirror] Push to origin ($REMOTE_URL): success"
else
    # WARN level — visible in --log-git accountability window
    log_msg "[git-mirror] WARNING: Push to origin ($REMOTE_URL) FAILED — changes may not be synced"
    log_msg "[git-mirror] Error: $OUTPUT"
    echo "[git-mirror] WARNING: Push to origin FAILED — changes may not be synced" >&2
    echo "[git-mirror] Error: $OUTPUT" >&2
fi

exit 0
