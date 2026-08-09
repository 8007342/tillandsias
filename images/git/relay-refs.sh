#!/bin/sh
# @trace spec:git-mirror-service, spec:secrets-management
# Synchronous relay invoked by pre-receive and startup recovery. stdin is an
# exact `<oldsha> <newsha> <refname>` transaction; startup recovery represents
# its current local ref as old==new. Success means the configured upstream
# durably accepted the complete atomic ref set.

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

TMPDIR_WORK="$(mktemp -d 2>/dev/null || mktemp -d -t 'git-relay-refs')"
trap 'rm -rf "$TMPDIR_WORK"' EXIT
UPDATES_FILE="$TMPDIR_WORK/updates"
SEEN_REFS="$TMPDIR_WORK/seen-refs"
cat > "$UPDATES_FILE"
: > "$SEEN_REFS"

DELETE_COUNT=0
CREATE_UPDATE_COUNT=0
OID_SAMPLE="$(git hash-object --stdin </dev/null 2>/dev/null)" || {
    log_msg "Cannot determine repository object format; refusing relay"
    exit 1
}
OID_LENGTH="${#OID_SAMPLE}"
ZERO_SHA="$(printf '%*s' "$OID_LENGTH" '' | tr ' ' '0')"

# The relay is privileged independently of its caller. Re-validate the exact
# three-field receive grammar and repository state here rather than trusting
# pre-receive: alternate/direct callers must not gain a parser-smuggling bypass.
REJECTED=0
while read -r OLDSHA NEWSHA REFNAME EXTRA; do
    if [ -z "$OLDSHA" ] || [ -z "$NEWSHA" ] || [ -z "$REFNAME" ] || [ -n "${EXTRA:-}" ]; then
        log_msg "SAFETY: malformed receive transaction record"
        REJECTED=1
        continue
    fi
    if [ "${#OLDSHA}" -ne "$OID_LENGTH" ] || [ "${#NEWSHA}" -ne "$OID_LENGTH" ]; then
        log_msg "SAFETY: object ID width does not match repository object format"
        REJECTED=1
        continue
    fi
    case "$OLDSHA$NEWSHA" in
        *[!0-9a-f]*)
            log_msg "SAFETY: object ID is not lowercase hexadecimal"
            REJECTED=1
            continue
            ;;
    esac
    case "$REFNAME" in
        refs/*) ;;
        *)
            log_msg "SAFETY: refname is outside refs/*"
            REJECTED=1
            continue
            ;;
    esac
    if ! git check-ref-format "$REFNAME" >/dev/null 2>&1; then
        log_msg "SAFETY: invalid refname in receive transaction"
        REJECTED=1
        continue
    fi
    if grep -Fqx "$REFNAME" "$SEEN_REFS"; then
        log_msg "SAFETY: duplicate ref in receive transaction: $REFNAME"
        REJECTED=1
        continue
    fi
    printf '%s\n' "$REFNAME" >> "$SEEN_REFS"

    ACTUAL_SHA="$(git rev-parse --verify "$REFNAME" 2>/dev/null || true)"
    if [ "$OLDSHA" = "$ZERO_SHA" ]; then
        if [ -n "$ACTUAL_SHA" ]; then
            log_msg "SAFETY: stale old object ID does not match current ref: $REFNAME"
            REJECTED=1
            continue
        fi
    elif [ "$ACTUAL_SHA" != "$OLDSHA" ]; then
        log_msg "SAFETY: stale old object ID does not match current ref: $REFNAME"
        REJECTED=1
        continue
    fi

    if [ "$NEWSHA" = "$ZERO_SHA" ]; then
        DELETE_COUNT=$((DELETE_COUNT + 1))
        continue
    fi
    if ! git cat-file -e "$NEWSHA" 2>/dev/null; then
        log_msg "SAFETY: proposed object is unavailable: $REFNAME"
        REJECTED=1
        continue
    fi
    case "$REFNAME" in
        refs/heads/*)
            if [ "$(git cat-file -t "$NEWSHA" 2>/dev/null || true)" != "commit" ]; then
                log_msg "SAFETY: proposed branch tip is not a commit: $REFNAME"
                REJECTED=1
                continue
            fi
            if [ "$OLDSHA" != "$ZERO_SHA" ] \
               && ! git merge-base --is-ancestor "$OLDSHA" "$NEWSHA" 2>/dev/null; then
                log_msg "SAFETY: non-fast-forward branch update is disabled: $REFNAME"
                REJECTED=1
                continue
            fi
            ;;
    esac
    CREATE_UPDATE_COUNT=$((CREATE_UPDATE_COUNT + 1))
done < "$UPDATES_FILE"

if [ "$REJECTED" -ne 0 ]; then
    log_msg "SAFETY: refusing malformed or stale relay transaction"
    exit 1
fi

# Defense in depth for direct/helper callers: the live pre-receive path rejects
# every deletion before invoking this privileged relay, but no alternate caller
# may turn the mirror's service credential into delete authority either.
if [ "$DELETE_COUNT" -gt 0 ]; then
    log_msg "SAFETY: refusing $DELETE_COUNT upstream ref deletion(s); authenticated policy-aware cleanup is required"
    exit 1
fi

if [ "$CREATE_UPDATE_COUNT" -eq 0 ]; then
    log_msg "No refs supplied; nothing to relay"
    exit 0
fi

# Build one argv element per validated refspec. Never concatenate and unquoted-
# expand an attacker-influenced string: shell word splitting allowed an extra
# field such as `:refs/heads/victim` to become a second destructive refspec.
set --
while read -r OLDSHA NEWSHA REFNAME EXTRA; do
    if [ "$NEWSHA" != "$ZERO_SHA" ]; then
        set -- "$@" "$NEWSHA:$REFNAME"
    fi
done < "$UPDATES_FILE"

REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"

if [ -z "$REMOTE_URL" ]; then
    log_msg "No upstream configured; accepting as a durable local-only mirror update"
    exit 0
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
        # --atomic with one safely quoted argv element per validated refspec and
        # never --mirror/--all.
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
if OUTPUT="$(GIT_TERMINAL_PROMPT=0 git push --atomic "$PUSH_URL" "$@" 2>&1)"; then
    log_msg "Atomic push to $REMOTE_URL_REDACTED succeeded"
    unset PUSH_URL BARE_URL
    exit 0
fi

OUTPUT_REDACTED="$(redact_output "$OUTPUT")"
log_msg "Atomic push to $REMOTE_URL_REDACTED FAILED: $OUTPUT_REDACTED"

# @trace spec:git-mirror-service
# Rung 2 (order 500, repair B3): NEVER pre-reject a protected branch in the
# pre-receive hook — these hooks ship to every end-user mirror, and an
# unconditional guard would brick pushes to an ordinary UNPROTECTED main.
# Instead, when the UPSTREAM itself refuses the push for branch protection
# (GitHub prints "GH006" and/or "protected branch"), print actionable salvage
# advice on this failure path only. Fully neutral: triggered by upstream
# output, zero configuration required.
case "$OUTPUT" in
    *"protected branch"*|*GH006*)
        SALVAGE_DATE="$(date -u '+%Y%m%d' 2>/dev/null || echo '<yyyymmdd>')"
        log_msg "ADVICE: upstream refused this push because the target branch is protected (pull-request only)."
        log_msg "ADVICE: land the same tree on a salvage branch for later triage instead:"
        log_msg "ADVICE:   git push origin HEAD:refs/heads/salvage/<host>/${SALVAGE_DATE}-<slug>"
        log_msg "ADVICE: replace <host> with your lowercase host name and <slug> with a short lowercase description of the work; the coordinator triages salvage/* branches and merges them properly later."
        ;;
esac

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
