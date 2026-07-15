#!/bin/sh
# @trace spec:git-mirror-service, spec:cross-platform, spec:windows-wsl-runtime
# Post-receive bookkeeping for Tillandsias mirrors.
#
# The must-succeed upstream relay runs in pre-receive. Post-receive cannot
# affect receive-pack's result, so it must never be used to establish durable
# acknowledgement semantics. This hook only records that the already-verified
# transaction was committed to the local mirror.

LOG_CANDIDATES="/var/log/tillandsias/git-push.log $HOME/.cache/tillandsias/git-push.log /tmp/git-push.log"
LOG_FILE=""
for candidate in $LOG_CANDIDATES; do
    dir="$(dirname "$candidate")"
    if [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null; then
        if : > "$candidate" 2>/dev/null || [ -w "$candidate" ]; then
            LOG_FILE="$candidate"
            break
        fi
    fi
done

log_msg() {
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')"
    if [ -n "$LOG_FILE" ]; then
        echo "$timestamp [post-receive] $1" >> "$LOG_FILE" 2>/dev/null
    fi
    echo "[post-receive] $1" >&2
}

COUNT=0
while read -r OLDSHA NEWSHA REFNAME; do
    [ -n "$REFNAME" ] || continue
    COUNT=$((COUNT + 1))
done

if git remote get-url origin >/dev/null 2>&1; then
    log_msg "Committed $COUNT upstream-verified ref update(s) to the local mirror"
else
    log_msg "Committed $COUNT durable local-only ref update(s) (no upstream configured)"
fi
exit 0
