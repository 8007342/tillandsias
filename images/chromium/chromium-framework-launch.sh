#!/usr/bin/env bash
set -euo pipefail

find_chromium() {
    if command -v chromium >/dev/null 2>&1; then
        command -v chromium
        return 0
    fi
    if command -v chromium-browser >/dev/null 2>&1; then
        command -v chromium-browser
        return 0
    fi
    return 1
}

accepts_no_sandbox() {
    local bin="$1"
    # Some Chromium wrappers reject unknown switches before launching. Keep the
    # hardening fallback only where the binary advertises the flag.
    "$bin" --help 2>&1 | grep -q -- '--no-sandbox'
}

CHROMIUM_BIN="$(find_chromium || true)"
if [[ -z "$CHROMIUM_BIN" ]]; then
    echo "chromium framework launcher: no chromium binary found" >&2
    exit 127
fi

ARGS=(
    "$@"
    "--disable-crash-reporter"
    "--disable-breakpad"
    "--disable-sync"
)

if accepts_no_sandbox "$CHROMIUM_BIN"; then
    # Chromium's setuid sandbox cannot launch inside our hardening
    # (--cap-drop=ALL + --security-opt=no-new-privileges); the container exits
    # 21 ("no usable sandbox") without this flag. The container itself remains
    # locked down via userns, dropped caps, no-new-privileges, and tmpfs mounts.
    ARGS+=("--no-sandbox")
fi

exec "$CHROMIUM_BIN" "${ARGS[@]}"
