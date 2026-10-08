#!/bin/sh
# Miniflare records generated files adjacent to its installed package. The
# image makes that path a symlink into the caller-provided private /tmp tmpfs,
# so a read-only project/source filesystem remains usable.
set -eu
mkdir -p /tmp/wrangler-miniflare /tmp/wrangler-project
exec /opt/tillandsias/wrangler/node_modules/.bin/wrangler "$@"
