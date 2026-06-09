#!/bin/sh
# @trace spec:git-mirror-service, spec:cross-platform, spec:windows-wsl-runtime
# Template post-receive hook for git mirrors managed by Tillandsias.
# Installed into each mirror's hooks/post-receive directory.
#
# Pushes JUST THE REFS THAT WERE UPDATED in this forge push to the configured
# origin remote. Always exits 0 — never blocks the forge's push even if the
# remote push fails.
#
# DO NOT USE `git push --mirror` HERE. The enclave mirror is a sparse cache
# that only contains refs the forge has pushed; `--mirror` would instruct
# GitHub to delete every other branch and tag (it nearly destroyed the
# upstream repo before this safer hook landed — see wave 24).
#
# Two host environments:
#   - Linux/podman: hook runs inside tillandsias-git container; /var/log/tillandsias/
#     is mounted RW.
#   - Windows/WSL : hook runs in the forge distro's process context against the
#     bare mirror on /mnt/c/...; /var/log/tillandsias/ does NOT exist there.
# We try the canonical log path first, fall back to a writable location, and
# always echo to stderr so the runtime-diagnostics stream can capture it.

# @trace spec:cross-platform, spec:runtime-diagnostics-stream
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
        echo "$timestamp $1" >> "$LOG_FILE" 2>/dev/null
    fi
    # Always to stderr so runtime-diagnostics streams pick it up.
    echo "$1" >&2
    # Also stdout so the forge's `git push` shows it.
    echo "$1"
}

REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"

if [ -z "$REMOTE_URL" ]; then
    log_msg "[git-mirror] No remote configured, skipping push"
    exit 0
fi

# Read the refs that were just updated in this push from stdin. Git invokes
# post-receive with one line per ref: `<oldsha> <newsha> <refname>`. We push
# exactly those refs upstream — nothing more, nothing less.
#
# Build a list of refspecs:
#   - `<newsha>:<refname>` to create/update the ref upstream
#   - `:<refname>` (with a leading colon) to delete the ref upstream when
#     the forge explicitly deleted it (newsha is the 40-zero string)
#
# A forge that pushes one branch produces exactly one refspec. We NEVER touch
# refs the forge didn't mention. This is the critical safety property.
REFSPECS=""
DELETE_COUNT=0
CREATE_UPDATE_COUNT=0
ZERO_SHA="0000000000000000000000000000000000000000"

while read -r OLDSHA NEWSHA REFNAME; do
    if [ -z "$REFNAME" ]; then
        continue
    fi
    if [ "$NEWSHA" = "$ZERO_SHA" ]; then
        REFSPECS="$REFSPECS :$REFNAME"
        DELETE_COUNT=$((DELETE_COUNT + 1))
    else
        REFSPECS="$REFSPECS $NEWSHA:$REFNAME"
        CREATE_UPDATE_COUNT=$((CREATE_UPDATE_COUNT + 1))
    fi
done

if [ -z "$REFSPECS" ]; then
    log_msg "[git-mirror] No refs updated, skipping upstream push"
    exit 0
fi

# Safety guard: refuse to forward more than 10 deletions in a single push.
# If the forge somehow tries to mass-delete (or a buggy launcher feeds us a
# bogus ref list), fail loud rather than silently destroy upstream refs.
# Override with TILLANDSIAS_ALLOW_BULK_DELETE=1 if you really want it.
if [ "$DELETE_COUNT" -gt 10 ] && [ "${TILLANDSIAS_ALLOW_BULK_DELETE:-0}" != "1" ]; then
    log_msg "[git-mirror] SAFETY: refusing to forward $DELETE_COUNT deletions to upstream (set TILLANDSIAS_ALLOW_BULK_DELETE=1 to override)"
    exit 0
fi

log_msg "[git-mirror] Forwarding $CREATE_UPDATE_COUNT update(s) and $DELETE_COUNT deletion(s) to upstream"

# @trace spec:tillandsias-vault, spec:secrets-management, spec:cross-platform, spec:git-mirror-service
# Construct an EPHEMERAL auth URL by reading the GitHub token at push time.
#
# Vault-only flow: read from Vault via vault-cli using the AppRole token
# mounted at /run/secrets/vault-token. The token lives in this process
# variable only; it never touches disk.
TOKEN=""
if [ -r /run/secrets/vault-token ] && command -v vault-cli >/dev/null 2>&1; then
    TOKEN="$(vault-cli read -field=token secret/github/token 2>/dev/null || true)"
fi

# Redact for log output. Always.
redact_url() { echo "$1" | sed -E 's#https://[^@/]+@#https://***@#'; }
redact_output() { echo "$1" | sed -E 's#https://[^@/]+@#https://***@#g'; }

# Build the push URL — clean URL when no token (will fail visibly), or
# token-injected when we have one. The token-injected URL is constructed in
# memory only; never written to disk.
PUSH_URL="$REMOTE_URL"
if [ -n "$TOKEN" ] && case "$REMOTE_URL" in https://*) true ;; *) false ;; esac; then
    # Strip any existing user:pass and inject oauth2:TOKEN.
    BARE="$(echo "$REMOTE_URL" | sed -E 's#https://[^@/]+@#https://#')"
    PUSH_URL="$(echo "$BARE" | sed -E "s#https://#https://oauth2:${TOKEN}@#")"
fi

REMOTE_URL_REDACTED="$(redact_url "$REMOTE_URL")"

# Run the push with the explicit refspec list. Word-splitting on $REFSPECS is
# intended — each refspec is a single shell word with no whitespace inside it.
# shellcheck disable=SC2086
if OUTPUT="$(git push "$PUSH_URL" $REFSPECS 2>&1)"; then
    log_msg "[git-mirror] Push to origin ($REMOTE_URL_REDACTED): success"
else
    OUTPUT_REDACTED="$(redact_output "$OUTPUT")"
    log_msg "[git-mirror] WARNING: Push to origin ($REMOTE_URL_REDACTED) FAILED — changes may not be synced"
    log_msg "[git-mirror] Error: $OUTPUT_REDACTED"
    echo "[git-mirror] WARNING: Push to origin FAILED — changes may not be synced" >&2
    echo "[git-mirror] Error: $OUTPUT_REDACTED" >&2
fi

# Wipe the local PUSH_URL var even though it's process-scoped, defense in depth.
unset PUSH_URL TOKEN BARE

exit 0
