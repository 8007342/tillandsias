#!/usr/bin/env bash
# entrypoint-forge-opencode-web.sh — OpenCode Web forge entrypoint.
#
# Lifecycle: source common -> require OpenCode from tools overlay ->
#            install OpenSpec -> clone project from git mirror ->
#            openspec init -> exec opencode serve (no banner, no TTY)
#
# Secrets: gh credentials, git config, cache. No Claude secrets.
# Unlike the CLI variant, there is no TTY and no user-facing banner —
# this entrypoint drives a headless HTTP server rendered in a host webview.
#
# @trace spec:opencode-web-session, spec:default-image, spec:environment-runtime, spec:layered-tools-overlay, spec:secrets-management

source /usr/local/lib/tillandsias/lib-common.sh

# @trace spec:forge-hot-cold-split, spec:agent-cheatsheets
# Populate tmpfs hot mount (/opt/cheatsheets) from image-baked lower layer.
# The --tmpfs mount is already in place (podman establishes it before exec).
populate_hot_paths

# @trace spec:proxy-container
# Trust the Tillandsias enclave CA chain for HTTPS proxy caching.
# System trust store updates require root (denied under --cap-drop=ALL).
# Instead, create a combined CA bundle (system CAs + proxy CA) in /tmp
# and export SSL_CERT_FILE / REQUESTS_CA_BUNDLE so curl, pip, and other
# OpenSSL-based tools trust the MITM proxy. Node.js uses NODE_EXTRA_CA_CERTS
# (set by podman env) which adds to its built-in trust store separately.
CA_CHAIN="/run/tillandsias/ca-chain.crt"
if [ -f "$CA_CHAIN" ]; then
    # @trace spec:environment-runtime — CA trust: Fedora uses pki, Alpine uses ca-certificates
    SYSTEM_CA=""
    if [ -f /etc/pki/tls/certs/ca-bundle.crt ]; then
        SYSTEM_CA=/etc/pki/tls/certs/ca-bundle.crt
    elif [ -f /etc/ssl/certs/ca-certificates.crt ]; then
        SYSTEM_CA=/etc/ssl/certs/ca-certificates.crt
    fi
    if [ -n "$SYSTEM_CA" ]; then
        COMBINED="/tmp/tillandsias-combined-ca.crt"
        cat "$SYSTEM_CA" "$CA_CHAIN" > "$COMBINED" 2>/dev/null
        export SSL_CERT_FILE="$COMBINED"
        export REQUESTS_CA_BUNDLE="$COMBINED"
    fi
fi

# @trace spec:opencode-web-session
trace_lifecycle "entrypoint" "opencode web starting"

# @trace spec:git-mirror-service, spec:forge-offline, spec:cross-platform, spec:windows-wsl-runtime
# Shared dual-transport clone — supports filesystem (Windows/WSL) and git
# daemon (Linux/podman). See lib-common.sh::clone_project_from_mirror.
clone_project_from_mirror

# ── OpenCode + OpenSpec (hard-installed) ───────────────────
# @trace spec:default-image, spec:forge-shell-tools, spec:opencode-web-session
require_opencode
require_openspec
apply_opencode_config_overlay

trace_lifecycle "entrypoint" "opencode web ready"

# ── Inference probe (async-inference-launch contract) ───────
# Non-blocking probe. OpenCode will surface a provider error at the moment
# the user invokes a local-LLM action if inference isn't ready yet.
# @trace spec:async-inference-launch, spec:inference-container
if command -v curl &>/dev/null; then
    if curl -m 1 -sf "http://inference:11434/api/version" >/dev/null 2>&1; then
        trace_lifecycle "inference" "ready (probe passed)"
    else
        trace_lifecycle "inference" "not-ready (probe failed; opencode will surface provider error if you try local inference)"
    fi
fi

# ── Find project directory ──────────────────────────────────
find_project_dir
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── OpenSpec init (every launch, silent) ────────────────────
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ]; then
    if ! OS_OUTPUT=$("$OS_BIN" init --tools opencode </dev/null 2>&1); then
        echo "[entrypoint] WARNING: OpenSpec init failed — /opsx commands may not work" >&2
        echo "[entrypoint] $OS_OUTPUT" >&2
    fi
fi

# ── Seed clean OpenCode state per-container ──────────────────
# @trace spec:opencode-web-session
# Why: OpenCode persists to three locations:
#   ~/.local/share/opencode   — SQLite db (projects, sessions, messages)
#   ~/.local/state/opencode   — runtime state (pty sockets, temp caches)
#   ~/.cache/opencode         — fetched assets, model blobs, internal caches
# Community reports of first-prompt hangs have been traced to stale cache
# directories (opencode.ai GH issues). Since Tillandsias forge containers are
# ephemeral, a fresh wipe on every start costs nothing and prevents stale-
# cache hangs + "global" pseudo-project cross-contamination.
for dir in "$HOME/.local/share/opencode" "$HOME/.local/state/opencode" "$HOME/.cache/opencode"; do
    if [ -d "$dir" ]; then
        rm -rf "$dir"
    fi
    mkdir -p "$dir"
done
trace_lifecycle "opencode-state" "cleared opencode share/state/cache (per-container seed)"

# ── Launch OpenCode Web Server (behind SSE keepalive proxy) ──
# @trace spec:opencode-web-session, spec:default-image
#
# Architecture:
#   client → 0.0.0.0:4096 (sse-keepalive-proxy.js) → 127.0.0.1:4097 (opencode)
#
# Bun's default HTTP idleTimeout is 10s. opencode serve doesn't override it
# and doesn't emit SSE keepalive comments, so `/event` and `/global/event`
# streams get dropped by the server 10s after the last byte. That breaks the
# web UI after the first prompt completes (the session goes idle, no bytes
# flow, Bun drops the stream, UI shows "frozen"). The proxy injects `:\n\n`
# (SSE comment) every 5s so bytes always flow → idleTimeout never trips.
#
# Sources: Bun docs https://bun.com/docs/runtime/http/server#idletimeout ,
# WHATWG HTML server-sent-events keepalive comment spec, Bun issue #27479.
#
# CWD is $PROJECT_DIR (set above). opencode uses cwd to pick which project
# the first request lands in, so this pins the container to the mounted
# project and prevents a "global" pseudo-project from dominating.
# @trace spec:cross-platform, spec:windows-wsl-runtime, spec:opencode-web-session
# OC_EXPOSED_PORT can be overridden via env so the host can pin the bind port
# to the dynamic host_port the tray allocated. On Linux/podman this is 4096
# (mapped via `-p <host_port>:4096`); on Windows/WSL we bind <host_port>
# directly because WSL2 forwards loopback binds verbatim to the Windows host.
OC_INTERNAL_PORT="${OC_INTERNAL_PORT:-4097}"
OC_EXPOSED_PORT="${OC_EXPOSED_PORT:-4096}"

trace_lifecycle "entrypoint" "opencode web serving on 127.0.0.1:$OC_INTERNAL_PORT (internal)"
"$OC_BIN" serve --hostname 127.0.0.1 --port "$OC_INTERNAL_PORT" &
OC_PID=$!

# Wait briefly for opencode to bind. If it fails early we exit with the
# opencode exit code so the tray's readiness probe and retry logic behave
# like before.
for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$OC_PID" 2>/dev/null; then
        wait "$OC_PID"
        exit $?
    fi
    if (exec 3<>/dev/tcp/127.0.0.1/$OC_INTERNAL_PORT) 2>/dev/null; then
        exec 3>&- 3<&-
        break
    fi
    sleep 0.5
done

# Forward SIGTERM/SIGINT to the opencode child so docker-style stop cleans up.
trap 'kill -TERM "$OC_PID" 2>/dev/null; wait "$OC_PID"; exit $?' TERM INT

trace_lifecycle "entrypoint" "sse-keepalive-proxy fronting :$OC_EXPOSED_PORT → :$OC_INTERNAL_PORT"
trace_lifecycle "exec" "launching sse-keepalive-proxy.js"
# Proxy runs in the foreground; when it exits, we also tear down opencode.
LISTEN_HOST=0.0.0.0 LISTEN_PORT=$OC_EXPOSED_PORT \
    UPSTREAM=127.0.0.1:$OC_INTERNAL_PORT \
    KEEPALIVE_MS=5000 \
    node /usr/local/bin/sse-keepalive-proxy.js
PROXY_EXIT=$?

kill -TERM "$OC_PID" 2>/dev/null
wait "$OC_PID" 2>/dev/null
exit "$PROXY_EXIT"
