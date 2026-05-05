#!/bin/bash
set -e
# @trace spec:git-mirror-service
# Entrypoint for the Tillandsias git service container.
# Runs git daemon in foreground, serving all repositories under /srv/git.
# Forge containers push here; post-receive hooks mirror to configured remotes.
# DISTRO: Alpine 3.20 — bash installed explicitly via apk add bash.
#         Uses POSIX-compatible constructs only (no [[ ]], no arrays).

# @trace spec:runtime-diagnostics
SLOG=/strategic/service.log
echo "$(date -Is) [git-service] starting git daemon on port 9418" >> "$SLOG" 2>/dev/null || SLOG=/dev/null

echo "========================================"
echo "  tillandsias git service"
echo "  listening on :9418"
echo "  base-path: /srv/git"
echo "========================================"

# GitHub token from podman secret.
# @trace spec:podman-secrets-integration, spec:git-mirror-service
# The tray creates tillandsias-github-token secret if a token is available
# in the OS keyring. Read it from /run/secrets/ (podman's standard location).
if [ -f /run/secrets/tillandsias-github-token ]; then
    export GITHUB_TOKEN
    GITHUB_TOKEN=$(cat /run/secrets/tillandsias-github-token)
    echo "GitHub token loaded from podman secret."
else
    echo "No GitHub token available; authenticated git operations will fail."
fi

# CA certificate from podman secret.
# @trace spec:podman-secrets-integration, spec:git-mirror-service
# Git CLI uses GIT_SSL_CAINFO to trust custom CA certificates.
# This allows git push --mirror to work through the enclave proxy.
if [ -f /run/secrets/tillandsias-ca-cert ]; then
    export GIT_SSL_CAINFO
    GIT_SSL_CAINFO=/run/secrets/tillandsias-ca-cert
    echo "CA certificate loaded from podman secret."
fi

# @trace spec:git-mirror-service
# Retry-on-startup: flush any commits that landed in the mirror while the
# previous session couldn't reach GitHub (e.g. the mirror had no HTTP_PROXY,
# or GitHub was transiently down). Each push is `--mirror origin` so it's
# idempotent — if mirror and remote are already in sync the push is a no-op.
# Errors are logged but don't block the daemon; the push is also rerun by
# the post-receive hook on the next forge commit.
#
# Bind-mounted mirror at /var/home/machiyotl/.cache/tillandsias/mirrors/<proj>
# persists across container lifecycles, so stranded commits from a prior
# session DO accumulate here — this sweep is their exit hatch.
GIT_RETRY_LOG="/var/log/tillandsias/git-push.log"
retry_msg() {
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')"
    echo "$timestamp $1" >> "$GIT_RETRY_LOG" 2>/dev/null
    echo "$1"
}
# Only do this on a real mirror tree (skip empty/init'ing service).
for mirror in /srv/git/*; do
    [ -d "$mirror" ] || continue
    REMOTE="$(git -C "$mirror" remote get-url origin 2>/dev/null || true)"
    [ -n "$REMOTE" ] || continue
    retry_msg "[git-mirror] Startup retry-push: $mirror -> $REMOTE"
    if OUTPUT="$(git -C "$mirror" push --mirror origin 2>&1)"; then
        retry_msg "[git-mirror] Startup retry-push OK"
    else
        retry_msg "[git-mirror] Startup retry-push FAILED: $OUTPUT"
    fi
done

echo "$(date -Is) [git-service] daemon ready" >> "$SLOG"

# Run git daemon as PID 1 so it receives signals properly.
exec git daemon \
    --reuseaddr \
    --export-all \
    --enable=receive-pack \
    --base-path=/srv/git \
    --listen=0.0.0.0 \
    --port=9418 \
    --verbose
