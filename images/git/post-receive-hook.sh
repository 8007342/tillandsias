#!/bin/sh
# @trace spec:git-mirror-service, spec:cross-platform, spec:windows-wsl-runtime
# Template post-receive hook for git mirrors managed by Tillandsias.
# Installed into each mirror's hooks/post-receive directory.
# Pushes to the configured origin remote after receiving from a forge container.
# Always exits 0 — never blocks the forge's push even if the remote push fails.
#
# Two host environments:
#   - Linux/podman: hook runs inside tillandsias-git container; /var/log/tillandsias/
#     is mounted RW.
#   - Windows/WSL : hook runs in the forge distro's process context against the
#     bare mirror on /mnt/c/...; /var/log/tillandsias/ does NOT exist there.
# We try the canonical log path first, fall back to a writable location, and
# always echo to stderr so --diagnostics catches every line.

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
    # Always to stderr so diagnostics streams pick it up.
    echo "$1" >&2
    # Also stdout so the forge's `git push` shows it.
    echo "$1"
}

REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"

if [ -z "$REMOTE_URL" ]; then
    log_msg "[git-mirror] No remote configured, skipping push"
    exit 0
fi

# @trace spec:secrets-management, spec:cross-platform, spec:git-mirror-service
# Construct an EPHEMERAL auth URL by injecting $GH_TOKEN at push time.
# The token is inherited from the parent process (git-daemon spawned with
# GH_TOKEN env on Windows; bind-mounted /run/secrets/github_token on Linux).
# Mirror's stored config has CLEAN URL only — no token persisted to disk.
#
# Linux flow uses /run/secrets/github_token; Windows flow uses GH_TOKEN env.
# Try env first (works on both); fall back to the secrets file (Linux).
TOKEN=""
if [ -n "${GH_TOKEN:-}" ]; then
    TOKEN="$GH_TOKEN"
elif [ -r /run/secrets/github_token ]; then
    TOKEN="$(cat /run/secrets/github_token 2>/dev/null || true)"
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

if OUTPUT="$(git push --mirror "$PUSH_URL" 2>&1)"; then
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
