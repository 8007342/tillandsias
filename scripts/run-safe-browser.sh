#!/usr/bin/env bash
# @trace spec:browser-isolation-core, spec:chromium-safe-variant, spec:browser-isolation-tray-integration
set -euo pipefail

URL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            shift
            URL="${1:-}"
            ;;
        --help|-h)
            cat <<'EOF'
Usage: scripts/run-safe-browser.sh --url <url>

Launch a minimal containerized Chromium framework browser in GUI app mode.
EOF
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            exit 2
            ;;
    esac
    shift
done

if [[ -z "$URL" ]]; then
    echo "error: --url is required" >&2
    exit 2
fi

if [[ "$URL" != *"://"* ]]; then
    URL="http://${URL}"
fi

# ORDER 798-rvqb: remote podman mode is CONFIGURATION, never inferred from a
# socket file existing (the ordinary state of any host with podman.socket
# enabled). This block, like build.sh's before 797-r6tc, arrived in the
# 406-file checkpoint ba5de86f4 with no rationale, and setting the variable
# makes common.sh pin TILLANDSIAS_PODMAN_BIN ahead of PATH. A caller that wants
# remote mode exports TILLANDSIAS_PODMAN_REMOTE_URL itself, as the systemd
# unit does. Pinned by scripts/lua/test-gate-podman-mode-configuration.lua.
# (This one also hardcoded /run/user/1000, so on any other uid it silently did
# nothing while reading as if it did something.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/launch-chromium.sh" safe-browser "$URL" 9222 open_safe_window
