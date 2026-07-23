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

# OLDSHA is part of receive-pack's pinned transaction grammar even though the
# relay needs only the proposed value and ref name.
# shellcheck disable=SC2034
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
# Probe the GitHub token from Vault at push time. Vault Agent owns renewal and
# re-authentication of the mirror's client token; this hook never caches one
# generation or tries to compete with Agent's lifecycle.
HAVE_UPSTREAM_TOKEN=0
HAVE_VAULT_CLI=0
# VAULT_TOKEN_FILE points at Vault Agent's renewable tmpfs sink in production;
# fixtures may point it at a temporary generation file.
VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-/run/secrets/vault-token}"
if command -v vault-cli >/dev/null 2>&1; then
    HAVE_VAULT_CLI=1
    if [ -r "$VAULT_TOKEN_FILE" ] \
       && vault-cli read -field=token secret/github/token >/dev/null 2>&1; then
        HAVE_UPSTREAM_TOKEN=1
    fi
fi

redact_url() { echo "$1" | sed -E 's#https://[^@/]+@#https://***@#'; }
redact_output() { echo "$1" | sed -E 's#https://[^@/]+@#https://***@#g'; }

PUSH_URL="$REMOTE_URL"
case "$REMOTE_URL" in
    https://*)
        if [ "$HAVE_UPSTREAM_TOKEN" -ne 1 ]; then
            # @trace spec:tillandsias-vault, spec:git-mirror-service
            # Distinguish an unhealthy Vault Agent sink from an ABSENT GitHub
            # token. If our current client token cannot look itself up, the
            # auto-auth path is still re-authenticating or has failed; blaming
            # GitHub Login would send the operator down the wrong path.
            if [ "$HAVE_VAULT_CLI" -eq 1 ] && ! vault-cli lookup-self >/dev/null 2>&1; then
                log_msg "git-mirror Vault Agent token is expired or unavailable while auto-auth re-authenticates. The GitHub credential itself is likely valid — do NOT run GitHub Login. Inspect the [vault-agent] log if this persists."
            else
                log_msg "HTTPS upstream credential is unavailable; run GitHub Login before pushing"
            fi
            exit 1
        fi
        # Order 424: the URL stays CLEAN. The token used to be interpolated
        # here and passed as an argv element to git push/fetch, which put it in
        # /proc/<pid>/cmdline and contradicted this repo's own stated invariant
        # ("never appears in process argv", vault-cli.sh). Git's credential
        # protocol hands it over on stdin instead.
        PUSH_URL="$(echo "$REMOTE_URL" | sed -E 's#https://[^@/]+@#https://#')"
        # Configure the helper via the ENVIRONMENT, not `git -c`, so the
        # relay's command shape stays exactly as pinned by
        # litmus:git-mirror-relay-verified-ack — that grep proves the push is
        # --atomic with explicit refspecs and never --mirror/--all, which is
        # the invariant that stops a repack from deleting upstream branches.
        # Credential wiring must not cost us that proof.
        #
        # GIT_CONFIG_COUNT/KEY/VALUE is git's documented env form. The empty
        # first helper RESETS inherited ones: credential.helper is ADDITIVE and
        # a leftover helper would otherwise be consulted first
        # (gitcredentials(7)).
        GIT_CONFIG_COUNT=2
        GIT_CONFIG_KEY_0=credential.helper
        GIT_CONFIG_VALUE_0=""
        GIT_CONFIG_KEY_1=credential.helper
        GIT_CREDENTIAL_HELPER="${GIT_CREDENTIAL_HELPER:-/usr/local/bin/git-credential-tillandsias}"
        GIT_CONFIG_VALUE_1="$GIT_CREDENTIAL_HELPER"
        export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 \
               GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1
        ;;
esac

REMOTE_URL_REDACTED="$(redact_url "$REMOTE_URL")"
log_msg "Relaying $CREATE_UPDATE_COUNT update(s) and $DELETE_COUNT deletion(s) atomically to $REMOTE_URL_REDACTED"

# Fetch upstream state BEFORE pushing so stale mirror tracking refs do not
# cause a non-fast-forward rejection on a clean host.
#
# Refspecs are MANDATORY and MUST be explicit. `git fetch <url>` with no
# refspec ignores remote.origin.fetch entirely and updates ZERO refs (it only
# writes FETCH_HEAD), while still reporting success — the mirror's exported
# heads never advance, so an agent's fetch/rebase/retry loop reads the same
# stale state forever and can never converge. See order 415.
#
# This pre-push fetch updates ONLY the tracking namespace
# (refs/remotes/origin/*). It MUST NOT touch the mirror's exported
# refs/heads/*: advancing an exported head before the relay decision would
# pre-empt the rejection path, so a genuinely stale push would no longer be
# refused and the post-failure reconcile (which is what teaches the agent to
# rebase) would never fire. Fetching upstream into a separate namespace so it
# can never clobber agent-pushed heads is the documented safe shape.
# Exported heads are fast-forwarded only by the reconcile below, after a
# rejection.
#
# A fetch failure is non-fatal — the push will fail visibly and the
# post-failure reconcile will retry.
# Escape quarantine so fetched objects are persisted to the main database.
if [ "$CREATE_UPDATE_COUNT" -gt 0 ]; then
    log_msg "Pre-push fetch from upstream (staleness guard)..."
    # shellcheck disable=SC2086
    if PRE_FETCH="$(env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
        git fetch "$PUSH_URL" '+refs/heads/*:refs/remotes/origin/*' 2>&1)"; then
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
    unset PUSH_URL BARE_URL
    exit 0
fi

OUTPUT_REDACTED="$(redact_output "$OUTPUT")"
log_msg "Atomic push to $REMOTE_URL_REDACTED FAILED: $OUTPUT_REDACTED"

if [ -n "$PUSH_URL" ]; then
    log_msg "Attempting non-forced reconcile fetch from upstream..."
    # Explicit non-forced refspecs are mandatory here for the same reason as the
    # pre-push fetch above: a bare `git fetch <url>` updates zero refs while
    # reporting success, which strands the agent's retry loop permanently.
    # Escape quarantine so fetched objects are persisted to the main database
    if FETCH_OUTPUT="$(env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
        git fetch "$PUSH_URL" 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' '+refs/heads/*:refs/remotes/origin/*' 2>&1)"; then
        log_msg "Reconcile fetch succeeded: exported heads fast-forwarded to upstream where possible."
    else
        FETCH_OUTPUT_REDACTED="$(redact_output "$FETCH_OUTPUT")"
        log_msg "Reconcile fetch non-fast-forward (expected if locally stranded): $FETCH_OUTPUT_REDACTED"
    fi
fi

unset PUSH_URL BARE_URL
exit 1
