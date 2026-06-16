#!/usr/bin/env bash
# entrypoint-forge-opencode-web.sh — OpenCode Web forge entrypoint.
#
# Lifecycle: source common -> require OpenCode + OpenSpec (hard-installed) ->
#            clone project from git mirror -> openspec init ->
#            exec opencode serve (no banner, no TTY)
#
# Secrets: git identity env only; GitHub token stays in git service.
# Unlike the CLI variant, there is no TTY and no user-facing banner —
# this entrypoint drives a headless HTTP server rendered in a host webview.
#
# @trace spec:browser-isolation-tray-integration, spec:default-image, spec:environment-runtime, spec:secrets-management, spec:simplified-tray-ux

source /usr/local/lib/tillandsias/lib-common.sh

# @trace gap:ON-008
# Load agent profile configuration from config overlay.
# This exports AGENT_PROFILE, AGENT_SUPPORTS_WEB, and related variables
# based on the user's preferred agent (claude, opencode, opencode-web).
if [ -f /opt/config-overlay/mcp/agent-profile.sh ]; then
    source /opt/config-overlay/mcp/agent-profile.sh
fi

# @trace spec:forge-git-identity-anonymization
# Agent attribution for git commit trailers.
export TILLANDSIAS_AGENT_NAME="OpenCode"
export TILLANDSIAS_GENERATED_BY="tool=opencode"

# @trace spec:proxy-container
# Trust the Tillandsias enclave CA chain for HTTPS proxy caching.
# System trust store updates require root (denied under --cap-drop=ALL).
# Instead, create a combined CA bundle (system CAs + proxy CA) in /tmp
# and export SSL_CERT_FILE / REQUESTS_CA_BUNDLE so curl, pip, and other
# OpenSSL-based tools trust the MITM proxy. Node.js uses NODE_EXTRA_CA_CERTS
# (set by podman env) which adds to its built-in trust store separately.
CA_CHAIN="/run/tillandsias/ca-chain.crt"
if [ -f "$CA_CHAIN" ]; then
    # @trace spec:environment-runtime
    # CA trust: Fedora uses pki, Alpine uses ca-certificates
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

# @trace spec:host-browser-mcp
trace_lifecycle "entrypoint" "opencode web starting"

# @trace spec:git-mirror-service, spec:forge-offline, spec:cross-platform, spec:windows-wsl-runtime
# Shared project materialization routine. It uses a host-mounted project when
# the launcher provides one, otherwise it clones from the git mirror.
clone_project_from_mirror

# ── OpenCode + OpenSpec (hard-installed) ───────────────────
# @trace spec:default-image, spec:forge-shell-tools, spec:simplified-tray-ux
require_opencode
apply_opencode_config_overlay
require_openspec

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

# ── SSH key auto-discovery ──────────────────────────────────
# @trace gap:ON-007
# Automatically discover and export SSH keys/agent from the host.
# This enables SSH-based git operations without manual configuration.
export_ssh_env || true

# ── Find project directory ──────────────────────────────────
find_project_dir

# ── Export project environment ───────────────────────────────
# @trace spec:forge-environment-discoverability
# Export discovery env vars: TILLANDSIAS_PROJECT_PATH, TILLANDSIAS_PROJECT_GENUS
export_project_env

[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
configure_git_identity
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── OpenSpec init (every launch, silent) ────────────────────
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ]; then
    if ! OS_OUTPUT=$("$OS_BIN" init --tools opencode </dev/null 2>&1); then
        echo "[entrypoint] WARNING: OpenSpec init failed — /opsx commands may not work" >&2
        echo "[entrypoint] $OS_OUTPUT" >&2
    fi
fi

# ── Launch OpenCode Web Server ──────────────────────────────
# @trace spec:browser-isolation-tray-integration, spec:default-image
# OpenCode serves on loopback :4097. The local SSE/theme proxy owns :4096,
# injects the dark-theme bootstrap, strips service-worker headers, and keeps
# event streams alive for the browser-facing route.
trace_lifecycle "entrypoint" "opencode web serving behind local proxy on 0.0.0.0:4096"
trace_lifecycle "exec" "launching opencode serve upstream ($OC_BIN)"
"$OC_BIN" serve --hostname 127.0.0.1 --port 4097 &
OC_PID=$!
cleanup() {
    kill "$OC_PID" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

export LISTEN_PORT=4096
export UPSTREAM=127.0.0.1:4097
exec /usr/local/bin/sse-keepalive-proxy.js
