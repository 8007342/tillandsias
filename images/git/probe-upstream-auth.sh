#!/bin/sh
# @trace spec:git-mirror-service, spec:meta-orchestration
# probe-upstream-auth <bare-mirror-dir>
#
# Order 756-2jnj (child of order 424): NON-MUTATING upstream WRITE-authorization
# probe. On 2026-08-15 a fresh-Windows forge lost two commits because the
# credential guard said ok:forge-git-mirror on REACHABILITY alone, while the
# mirror's Vault credential could not push upstream (GitHub 403 "Permission to
# 8007342/tillandsias.git denied") — a fact nobody learned until the FIRST push,
# hours after worker drain began. The verified-ack refusal worked as designed;
# detection was just too late. This probe moves that discovery to cycle start.
#
# WHAT IT PROVES. A `git push --dry-run` against the configured upstream fetches
# the receive-pack ref advertisement AUTHENTICATED with the same Vault-backed
# credential helper the live relay uses (order 424: token travels on stdin,
# never argv/env/URL). GitHub authorizes that advertisement request itself:
# 200 = the credential may push, 403 = it may not. --dry-run never sends a
# pack and never updates any upstream ref — no canary ref, nothing mutated.
#
# WHERE THE VERDICT GOES. The forge can only see the mirror through the git
# daemon, so the verdict is published as a ref the daemon already advertises:
#
#   refs/tillandsias/upstream-auth/<state>/<epoch>
#
# <state> is one of authorized | denied | no-credential | local-only | error;
# <epoch> is the probe's unix time, so a consumer can bound staleness
# (yesterday's verdict is from yesterday's token epoch — the bug in a hat).
# The namespace is OUTSIDE refs/heads and refs/tags, so the startup retry
# sweep, the reconcile passes, and clones all ignore it; it is never relayed
# upstream. Exactly one ref is kept: the new verdict is written first, then
# older ones are pruned (a crash between the two leaves extra refs, and the
# consumer picks the largest epoch).
#
# The consumer is scripts/check-credential-channel.sh (forge branch), which
# reads it via `git ls-remote origin 'refs/tillandsias/upstream-auth/*'` —
# the same transport a push takes.
#
# Emits exactly one line on stdout matching the falsifiable grammar
#   ^upstream-auth:(authorized|denied|no-credential|local-only|error):[0-9]+$
# and exits 0 (authorized | local-only) or 1 (denied | no-credential | error);
# 2 is usage. Diagnostics go to stderr/log, always credential-redacted.
#
# Testability seams (same pattern as RELAY_REF/ENSURE_HEAD/RECONCILE_HEADS):
#   PUSH_PROBE  — executable invoked as `$PUSH_PROBE <push-url> <refspec>`
#                 instead of the real `git push --dry-run`, so fixtures can
#                 replay the exact 2026-08-15 GitHub 403 offline.
#   VAULT_CLI   — vault client command (default vault-cli); fixtures point it
#                 at a nonexistent path to model an ABSENT upstream credential.

LOG_CANDIDATES="/var/log/tillandsias/git-push.log $HOME/.cache/tillandsias/git-push.log /tmp/git-push.log"
LOG_FILE=""
for candidate in $LOG_CANDIDATES; do
    dir="$(dirname "$candidate")"
    if [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null; then
        if : >> "$candidate" 2>/dev/null || [ -w "$candidate" ]; then
            LOG_FILE="$candidate"
            break
        fi
    fi
done

log_msg() {
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')"
    if [ -n "$LOG_FILE" ]; then
        echo "$timestamp [upstream-auth] $1" >> "$LOG_FILE" 2>/dev/null
    fi
    echo "[upstream-auth] $1" >&2
}

redact_output() { echo "$1" | sed -E 's#https://[^@/]+@#https://***@#g'; }

MIRROR="${1:-}"
if [ -z "$MIRROR" ] || [ ! -d "$MIRROR" ]; then
    echo "probe-upstream-auth: usage: probe-upstream-auth <bare-mirror-dir>" >&2
    exit 2
fi

EPOCH="$(date -u +%s)"

# Publish <state> as the single ref in the verdict namespace and print the
# probe's one-line verdict. The ref target is the empty blob — always
# writable, never confusable with project history.
publish() {
    state="$1"
    new_ref="refs/tillandsias/upstream-auth/$state/$EPOCH"
    if blob="$(git -C "$MIRROR" hash-object -w --stdin </dev/null 2>/dev/null)" \
       && git -C "$MIRROR" update-ref "$new_ref" "$blob" 2>/dev/null; then
        for old in $(git -C "$MIRROR" for-each-ref --format='%(refname)' refs/tillandsias/upstream-auth 2>/dev/null); do
            [ "$old" = "$new_ref" ] && continue
            git -C "$MIRROR" update-ref -d "$old" 2>/dev/null || true
        done
    else
        # Publication failure is loud but does not change the verdict: the
        # consumer treats an absent/stale ref as blocked, which fails closed.
        log_msg "WARNING: could not publish $new_ref in $MIRROR"
    fi
    echo "upstream-auth:$state:$EPOCH"
}

finish() {
    state="$1"
    publish "$state"
    case "$state" in
        authorized|local-only) exit 0 ;;
        *) exit 1 ;;
    esac
}

REMOTE_URL="$(git -C "$MIRROR" remote get-url origin 2>/dev/null || true)"
if [ -z "$REMOTE_URL" ]; then
    # No upstream configured: relay-refs accepts pushes as durable local-only
    # mirror updates, so the write channel IS usable.
    finish local-only
fi

PUSH_URL="$REMOTE_URL"
case "$REMOTE_URL" in
    https://*)
        # Same credential discovery as relay-refs.sh: Vault Agent owns the
        # token lifecycle; we only check that a token is CURRENTLY readable.
        # The secret value itself is discarded (>/dev/null) — never printed,
        # never persisted.
        VAULT_CLI="${VAULT_CLI:-vault-cli}"
        VAULT_TOKEN_FILE="${VAULT_TOKEN_FILE:-/run/secrets/vault-token}"
        if ! command -v "$VAULT_CLI" >/dev/null 2>&1 \
           || [ ! -r "$VAULT_TOKEN_FILE" ] \
           || ! "$VAULT_CLI" read -field=token secret/github/token >/dev/null 2>&1; then
            log_msg "no upstream credential is currently readable from Vault; a push would fail before reaching GitHub"
            finish no-credential
        fi
        # Keep the URL clean (order 424) and wire the same stdin credential
        # helper the relay uses, via the ENVIRONMENT so the probe's command
        # shape stays a plain `git push --dry-run`.
        PUSH_URL="$(echo "$REMOTE_URL" | sed -E 's#https://[^@/]+@#https://#')"
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

# Any existing local head works: the authorization answer arrives with the ref
# advertisement, before git compares a single commit. Old-sha/new-sha content
# is irrelevant under --dry-run.
PROBE_REF="$(git -C "$MIRROR" for-each-ref --format='%(refname)' refs/heads 2>/dev/null | head -n 1)"
if [ -z "$PROBE_REF" ]; then
    log_msg "mirror has no local heads to probe with (still seeding?); cannot determine authorization"
    finish error
fi
PROBE_SHA="$(git -C "$MIRROR" rev-parse "$PROBE_REF" 2>/dev/null)"
if [ -z "$PROBE_SHA" ]; then
    log_msg "cannot resolve $PROBE_REF; cannot determine authorization"
    finish error
fi

if [ -n "${PUSH_PROBE:-}" ]; then
    OUT="$("$PUSH_PROBE" "$PUSH_URL" "$PROBE_SHA:$PROBE_REF" 2>&1)" && rc=0 || rc=$?
else
    OUT="$(GIT_TERMINAL_PROMPT=0 timeout "${AUTH_PROBE_TIMEOUT:-30}" \
        git -C "$MIRROR" push --dry-run "$PUSH_URL" "$PROBE_SHA:$PROBE_REF" 2>&1)" && rc=0 || rc=$?
fi

if [ "$rc" -eq 0 ]; then
    finish authorized
fi

OUT_REDACTED="$(redact_output "$OUT")"
case "$OUT" in
    # Authorization/authentication failures. GitHub's 403 body is
    # "Permission to <repo> denied to <login>"; 401/credential-helper
    # failures surface as "Authentication failed", "could not read
    # Username", or "terminal prompts disabled".
    *"error: 403"*|*"Permission to "*|*"denied to "*|*"error: 401"*|*"Authentication failed"*|*"could not read Username"*|*"terminal prompts disabled"*|*"Invalid username or password"*)
        log_msg "upstream REFUSED the authenticated receive-pack advertisement — the credential cannot push: $OUT_REDACTED"
        finish denied
        ;;
    # The advertisement WAS served (authorization succeeded); the dry-run then
    # failed on ref policy (e.g. non-fast-forward). That is a data problem,
    # not an authorization problem — reconcile handles it.
    *"[rejected]"*|*"non-fast-forward"*|*"[remote rejected]"*)
        log_msg "advertisement served; dry-run rejected on ref policy (not an authorization failure): $OUT_REDACTED"
        finish authorized
        ;;
    *)
        log_msg "probe could not determine authorization (network/transport failure?): $OUT_REDACTED"
        finish error
        ;;
esac
