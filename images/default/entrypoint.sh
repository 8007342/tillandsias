#!/usr/bin/env bash
# DEPRECATED — kept for backward compatibility with cached images.
# New launches use per-type entrypoints directly via --entrypoint.
#
# This redirect ensures containers built with older image versions
# still work when launched by newer or older Rust binaries.
source /usr/local/lib/tillandsias/lib-common.sh

MAINTENANCE="${TILLANDSIAS_MAINTENANCE:-0}"
if [ "$MAINTENANCE" = "1" ]; then
    exec /usr/local/bin/entrypoint-terminal.sh "$@"
fi

case "${TILLANDSIAS_AGENT:-claude}" in
    opencode) exec /usr/local/bin/entrypoint-forge-opencode.sh "$@" ;;
    claude)   exec /usr/local/bin/entrypoint-forge-claude.sh "$@" ;;
    *)        exec /usr/local/bin/entrypoint-terminal.sh "$@" ;;
esac
