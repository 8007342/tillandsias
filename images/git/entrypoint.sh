#!/bin/bash
set -e
# @trace spec:git-mirror-service
# Entrypoint for the Tillandsias git service container.
# Runs git daemon in foreground, serving all repositories under /srv/git.
# Forge containers push here; post-receive hooks mirror to configured remotes.
# DISTRO: Alpine 3.20 — bash installed explicitly via apk add bash.
#         Uses POSIX-compatible constructs only (no [[ ]], no arrays).

# @trace spec:runtime-diagnostics
# Try the canonical strategic log path first, fall back to /dev/null when the
# container is launched with --read-only and /strategic isn't a tmpfs.
SLOG=/strategic/service.log
{ echo "$(date -Is) [git-service] starting git daemon on port 9418" >> "$SLOG"; } 2>/dev/null || SLOG=/dev/null

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
# Seed the project's bare repo + install the post-receive hook.
#
# The forge pushes via `git://git-service/<project>` (see
# `rewrite_origin_for_enclave_push` in images/default/lib-common.sh). The bare
# repo at /srv/git/<project> is what `git daemon --base-path=/srv/git` serves
# for the path `/<project>`. Without this block the daemon would respond with
# "fatal: '/<project>' does not appear to be a git repository" on the very
# first push.
#
# Idempotent: re-running on each container start only re-creates files that
# don't exist yet. The bare repo lives on a named podman volume mounted at
# /srv/git so committed objects survive container restarts.
if [ -n "$PROJECT" ]; then
    PROJECT_REPO=/srv/git/"$PROJECT"
    if [ ! -d "$PROJECT_REPO" ]; then
        echo "[git-service] initializing bare repo at $PROJECT_REPO"
        git init --bare "$PROJECT_REPO"
        # Accept whatever the forge pushes — initial syncs from a host clone
        # often look like force-pushes from the bare repo's perspective. The
        # post-receive hook downstream does `--mirror` to upstream which
        # already forces; locally we just accept the push.
        git -C "$PROJECT_REPO" config receive.denyNonFastforwards false
        git -C "$PROJECT_REPO" config receive.denyDeletes false
    fi
    if [ -n "$TILLANDSIAS_PROJECT_REMOTE_URL" ]; then
        # Redact any embedded credentials in the URL we log (defense in depth;
        # the launcher should pass a clean URL).
        REDACTED_URL="$(echo "$TILLANDSIAS_PROJECT_REMOTE_URL" | sed -E 's#https://[^@/]+@#https://***@#')"
        echo "[git-service] setting $PROJECT_REPO origin to $REDACTED_URL"
        git -C "$PROJECT_REPO" remote remove origin 2>/dev/null || true
        git -C "$PROJECT_REPO" remote add origin "$TILLANDSIAS_PROJECT_REMOTE_URL"
    else
        echo "[git-service] no TILLANDSIAS_PROJECT_REMOTE_URL set; post-receive hook will log and skip"
    fi
    if [ ! -e "$PROJECT_REPO/hooks/post-receive" ]; then
        cp /usr/local/share/git-service/post-receive-hook.sh "$PROJECT_REPO/hooks/post-receive"
        chmod +x "$PROJECT_REPO/hooks/post-receive"
        echo "[git-service] installed post-receive hook at $PROJECT_REPO/hooks/post-receive"
    fi
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
# Pick a writable log path. Under --read-only the bind-mounted /var/log/...
# isn't always available; fall through to /tmp (the image's tmpfs) or skip.
GIT_RETRY_LOG=""
for candidate in /var/log/tillandsias/git-push.log /tmp/git-push.log; do
    dir="$(dirname "$candidate")"
    if [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null; then
        if { : >> "$candidate"; } 2>/dev/null; then
            GIT_RETRY_LOG="$candidate"
            break
        fi
    fi
done
retry_msg() {
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')"
    if [ -n "$GIT_RETRY_LOG" ]; then
        { echo "$timestamp $1" >> "$GIT_RETRY_LOG"; } 2>/dev/null || true
    fi
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
