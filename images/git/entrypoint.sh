#!/bin/bash
set -e
# @trace spec:git-mirror-service
# Entrypoint for the Tillandsias git service container.
# Runs git daemon in foreground, serving all repositories under /srv/git.
# Forge containers push here; post-receive hooks mirror to configured remotes.
# DISTRO: Alpine 3.20 — bash installed explicitly via apk add bash.
#         Uses POSIX-compatible constructs only (no [[ ]], no arrays).

echo "========================================"
echo "  tillandsias git service"
echo "  listening on :9418"
echo "  base-path: /srv/git"
echo "========================================"

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

# Run git daemon as PID 1 so it receives signals properly.
exec git daemon \
    --reuseaddr \
    --export-all \
    --enable=receive-pack \
    --base-path=/srv/git \
    --listen=0.0.0.0 \
    --port=9418 \
    --verbose
