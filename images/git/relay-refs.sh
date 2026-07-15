#!/bin/sh
# @trace spec:git-mirror-service, spec:secrets-management
# Synchronous relay invoked only by pre-receive. stdin is receive-pack's
# `<oldsha> <newsha> <refname>` transaction. Success means the configured
# upstream durably accepted the complete atomic ref set.

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
        echo "$timestamp [relay] $1" >> "$LOG_FILE" 2>/dev/null
    fi
    echo "[relay] $1" >&2
}

REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"
if [ -z "$REMOTE_URL" ]; then
    log_msg "No upstream configured; accepting as a durable local-only mirror update"
    exit 0
fi

REFSPECS=""
DELETE_COUNT=0
CREATE_UPDATE_COUNT=0
ZERO_SHA="0000000000000000000000000000000000000000"

while read -r OLDSHA NEWSHA REFNAME; do
    [ -n "$REFNAME" ] || continue
    if [ "$NEWSHA" = "$ZERO_SHA" ]; then
        REFSPECS="$REFSPECS :$REFNAME"
        DELETE_COUNT=$((DELETE_COUNT + 1))
    else
        REFSPECS="$REFSPECS $NEWSHA:$REFNAME"
        CREATE_UPDATE_COUNT=$((CREATE_UPDATE_COUNT + 1))
    fi
done

if [ -z "$REFSPECS" ]; then
    log_msg "No refs supplied; nothing to relay"
    exit 0
fi

if [ "$DELETE_COUNT" -gt 10 ] && [ "${TILLANDSIAS_ALLOW_BULK_DELETE:-0}" != "1" ]; then
    log_msg "SAFETY: refusing $DELETE_COUNT upstream deletions (set TILLANDSIAS_ALLOW_BULK_DELETE=1 to override)"
    exit 1
fi

TOKEN=""
if [ -r /run/secrets/vault-token ] && command -v vault-cli >/dev/null 2>&1; then
    TOKEN="$(vault-cli read -field=token secret/github/token 2>/dev/null || true)"
fi

redact_url() { echo "$1" | sed -E 's#https://[^@/]+@#https://***@#'; }
redact_output() { echo "$1" | sed -E 's#https://[^@/]+@#https://***@#g'; }

PUSH_URL="$REMOTE_URL"
case "$REMOTE_URL" in
    https://*)
        if [ -z "$TOKEN" ]; then
            log_msg "HTTPS upstream credential is unavailable; run GitHub Login before pushing"
            exit 1
        fi
        BARE_URL="$(echo "$REMOTE_URL" | sed -E 's#https://[^@/]+@#https://#')"
        PUSH_URL="https://oauth2:${TOKEN}@${BARE_URL#https://}"
        ;;
esac

REMOTE_URL_REDACTED="$(redact_url "$REMOTE_URL")"
log_msg "Relaying $CREATE_UPDATE_COUNT update(s) and $DELETE_COUNT deletion(s) atomically to $REMOTE_URL_REDACTED"

# receive-pack exposes proposed objects through GIT_OBJECT_DIRECTORY and
# GIT_ALTERNATE_OBJECT_DIRECTORIES. Keep Git's quarantine marker intact here:
# an HTTPS/SSH upstream cannot inherit the local hook environment, and local
# transport fixtures must sanitize the receiver side explicitly.
# shellcheck disable=SC2086
if OUTPUT="$(GIT_TERMINAL_PROMPT=0 git push --atomic "$PUSH_URL" $REFSPECS 2>&1)"; then
    log_msg "Atomic push to $REMOTE_URL_REDACTED succeeded"
    unset PUSH_URL TOKEN BARE_URL
    exit 0
fi

OUTPUT_REDACTED="$(redact_output "$OUTPUT")"
log_msg "Atomic push to $REMOTE_URL_REDACTED FAILED: $OUTPUT_REDACTED"
unset PUSH_URL TOKEN BARE_URL
exit 1
