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

# Run git daemon as PID 1 so it receives signals properly.
exec git daemon \
    --reuseaddr \
    --export-all \
    --enable=receive-pack \
    --base-path=/srv/git \
    --listen=0.0.0.0 \
    --port=9418 \
    --verbose
