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

# @trace spec:tillandsias-vault, spec:git-mirror-service
# Read the GitHub token from Vault at push time. The mirror's own AppRole token
# has a 1h default TTL; the entrypoint renewer (order 414) keeps it alive, but
# best-effort renew here too so a push landing right after a missed heartbeat
# refreshes the lease before the read.
TOKEN=""
HAVE_VAULT_CLI=0
# VAULT_TOKEN_FILE mirrors vault-cli's own default so a test/fixture can point
# the mounted-token check at a temp file; production leaves it at the podman
# secret mount.
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-/run/secrets/vault-token}"
if [ -r "$VAULT_TOKEN_FILE" ] && command -v vault-cli >/dev/null 2>&1; then
    HAVE_VAULT_CLI=1
    vault-cli renew-self >/dev/null 2>&1 || true
    TOKEN="$(vault-cli read -field=token secret/github/token 2>/dev/null || true)"
fi

redact_url() { echo "$1" | sed -E 's#https://[^@/]+@#https://***@#'; }
redact_output() { echo "$1" | sed -E 's#https://[^@/]+@#https://***@#g'; }

PUSH_URL="$REMOTE_URL"
case "$REMOTE_URL" in
    https://*)
        if [ -z "$TOKEN" ]; then
            # @trace spec:tillandsias-vault, spec:git-mirror-service
            # Distinguish an EXPIRED MIRROR TOKEN from an ABSENT GitHub token
            # (order 414). If our own AppRole token cannot even look itself up,
            # the mirror's Vault access has expired (~1h TTL) — the GitHub
            # credential is almost certainly fine and "run GitHub Login" would
            # send the operator down the wrong path. The remedy is a re-mint.
            if [ "$HAVE_VAULT_CLI" -eq 1 ] && ! vault-cli lookup-self >/dev/null 2>&1; then
                log_msg "git-mirror Vault token is expired or unrenewable (AppRole ~1h TTL, not renewed). The GitHub credential itself is likely valid — do NOT run GitHub Login. Relaunch the forge to re-mint the mirror token (build_git_run_args uses --replace)."
            else
                log_msg "HTTPS upstream credential is unavailable; run GitHub Login before pushing"
            fi
            exit 1
        fi
        BARE_URL="$(echo "$REMOTE_URL" | sed -E 's#https://[^@/]+@#https://#')"
        PUSH_URL="https://oauth2:${TOKEN}@${BARE_URL#https://}"
        ;;
esac

REMOTE_URL_REDACTED="$(redact_url "$REMOTE_URL")"
log_msg "Relaying $CREATE_UPDATE_COUNT update(s) and $DELETE_COUNT deletion(s) atomically to $REMOTE_URL_REDACTED"

# Fetch upstream state BEFORE pushing so stale mirror tracking refs do not
# cause a non-fast-forward rejection on a clean host. Use the safe tracking
# refspec (refs/remotes/origin/*) so fetched heads never clobber the
# mirror's exported refs/heads/*. A fetch failure is non-fatal — the push
# will fail visibly and the post-failure reconcile will retry.
# Escape quarantine so fetched objects are persisted to the main database.
if [ "$CREATE_UPDATE_COUNT" -gt 0 ]; then
    log_msg "Pre-push fetch from upstream (staleness guard)..."
    # shellcheck disable=SC2086
    if PRE_FETCH="$(env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
        git fetch "$PUSH_URL" 2>&1)"; then
        log_msg "Pre-push fetch succeeded"
    else
        PRE_FETCH_REDACTED="$(redact_output "$PRE_FETCH")"
        log_msg "Pre-push fetch failed (non-fatal, push may still succeed): $PRE_FETCH_REDACTED"
    fi
fi

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

if [ -n "$PUSH_URL" ]; then
    log_msg "Attempting non-forced reconcile fetch from upstream..."
    # Escape quarantine so fetched objects are persisted to the main database
    if FETCH_OUTPUT="$(env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
        git fetch "$PUSH_URL" 2>&1)"; then
        log_msg "Reconcile fetch succeeded. Mirror is now up to date."
    else
        FETCH_OUTPUT_REDACTED="$(redact_output "$FETCH_OUTPUT")"
        log_msg "Reconcile fetch non-fast-forward (expected if locally stranded): $FETCH_OUTPUT_REDACTED"
    fi
fi

unset PUSH_URL TOKEN BARE_URL
exit 1
