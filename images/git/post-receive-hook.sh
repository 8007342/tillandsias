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
# 1956-4pxj: announce each accepted ref update to every host process that
# serves a lane of this project (one datagram per ref to each socket in the
# mounted event directory), so every OTHER forge of the project hears about
# it. REMOTE_ADDR is the pusher as git-daemon saw it, so the host can skip the
# pusher. Best-effort and bounded: a push never waits on a listener.
EVENT_DIR=/run/tillandsias/push-events
announce_push() {
    [ -d "$EVENT_DIR" ] || return 0
    command -v socat >/dev/null 2>&1 || return 0
    for sock in "$EVENT_DIR"/*.sock; do
        [ -S "$sock" ] || continue
        printf "push %s %s %s %s\n" "$3" "$1" "$2" "${REMOTE_ADDR:--}" \
            | timeout 2 socat -u - "UNIX-SENDTO:$sock" 2>/dev/null || true
    done
}
while read -r OLDSHA NEWSHA REFNAME; do
    [ -n "$REFNAME" ] || continue
    COUNT=$((COUNT + 1))
    announce_push "$OLDSHA" "$NEWSHA" "$REFNAME"
done

if git remote get-url origin >/dev/null 2>&1; then
    log_msg "Committed $COUNT upstream-verified ref update(s) to the local mirror"
else
    log_msg "Committed $COUNT durable local-only ref update(s) (no upstream configured)"
fi
exit 0
