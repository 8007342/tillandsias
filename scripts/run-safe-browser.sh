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

if [[ -z "${TILLANDSIAS_PODMAN_REMOTE_URL:-}" && -S /run/user/1000/podman/podman.sock ]]; then
    export TILLANDSIAS_PODMAN_REMOTE_URL="unix:///run/user/1000/podman/podman.sock"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/launch-chromium.sh" safe-browser "$URL" 9222 open_safe_window
