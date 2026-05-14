#!/usr/bin/env bash
# entrypoint-forge-opencode-web.sh — OpenCode Web forge entrypoint.
#
# Lifecycle: source common -> require OpenCode + OpenSpec (hard-installed) ->
#            clone project from git mirror -> openspec init ->
#            exec opencode serve (no banner, no TTY)
#
# Secrets: gh credentials, git config, cache. No Claude secrets.
# Unlike the CLI variant, there is no TTY and no user-facing banner —
# this entrypoint drives a headless HTTP server rendered in a host webview.
#
# @trace spec:browser-isolation-tray-integration, spec:default-image, spec:environment-runtime, spec:secrets-management, spec:simplified-tray-ux

source /usr/local/lib/tillandsias/lib-common.sh

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

# @trace spec:git-mirror-service, spec:forge-offline
# Clone project from git mirror. No TTY fallback — fatal on failure, same as CLI forge.
if [[ -n "${TILLANDSIAS_GIT_SERVICE:-}" ]] && [[ -n "${TILLANDSIAS_PROJECT:-}" ]]; then
    trace_lifecycle "git-mirror" "cloning from ${TILLANDSIAS_GIT_SERVICE}"
    MAX_RETRIES=5
    CLONE_SUCCESS=false
    CLONE_DIR="/home/forge/src/${TILLANDSIAS_PROJECT}"
    for i in $(seq 1 $MAX_RETRIES); do
        if git clone "git://${TILLANDSIAS_GIT_SERVICE}/${TILLANDSIAS_PROJECT}" "$CLONE_DIR" 2>&1; then
            trace_lifecycle "git-mirror" "clone successful"
            CLONE_SUCCESS=true
            cd "$CLONE_DIR"
            # @trace spec:git-mirror-service
            if ! git remote set-url --push origin "git://${TILLANDSIAS_GIT_SERVICE}/${TILLANDSIAS_PROJECT}" 2>/dev/null; then
                echo "[entrypoint] WARNING: Failed to set push URL — git push may not work" >&2
            fi
            # @trace spec:forge-offline
            if [[ -n "${GIT_AUTHOR_NAME:-}" ]]; then
                git config user.name "$GIT_AUTHOR_NAME"
            fi
            if [[ -n "${GIT_AUTHOR_EMAIL:-}" ]]; then
                git config user.email "$GIT_AUTHOR_EMAIL"
            fi
            break
        fi
        if [[ $i -lt $MAX_RETRIES ]]; then
            trace_lifecycle "git-mirror" "git service not ready, retrying ($i/$MAX_RETRIES)..."
            sleep 1
        else
            trace_lifecycle "git-mirror" "clone failed after $MAX_RETRIES attempts"
        fi
    done
    if [[ "$CLONE_SUCCESS" != "true" ]]; then
        echo "[forge] FATAL: git clone failed from git://${TILLANDSIAS_GIT_SERVICE}/${TILLANDSIAS_PROJECT}" >&2
        echo "[forge] The git mirror service is unreachable or has not finished initialising." >&2
        exit 1
    fi
    echo "[forge] All changes must be committed to persist. Uncommitted work is lost on stop."
fi

# ── OpenCode + OpenSpec (hard-installed) ───────────────────
# @trace spec:default-image, spec:forge-shell-tools, spec:simplified-tray-ux
require_opencode
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

# ── Launch OpenCode Web Server ──────────────────────────────
# @trace spec:browser-isolation-tray-integration, spec:default-image
# Headless HTTP server on 0.0.0.0:4096 inside the container. The host-side
# reverse-proxy route binds 127.0.0.1 only — enforced in the tray/launcher.
trace_lifecycle "entrypoint" "opencode web serving on 0.0.0.0:4096"
trace_lifecycle "exec" "launching opencode serve ($OC_BIN)"
exec "$OC_BIN" serve --hostname 0.0.0.0 --port 4096
