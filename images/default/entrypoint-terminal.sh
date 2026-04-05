#!/usr/bin/env bash
# entrypoint-terminal.sh — Maintenance terminal entrypoint.
#
# Lifecycle: source common -> install OpenSpec -> find project ->
#            openspec init -> welcome banner -> exec fish
#
# Secrets: gh credentials, git config only. No agent secrets.

source /usr/local/lib/tillandsias/lib-common.sh

# @trace spec:proxy-container
# Trust the Tillandsias enclave CA chain for HTTPS proxy caching.
# NOTE: update-ca-trust requires write access to /etc/pki/ which is denied
# under --cap-drop=ALL. The || true ensures this is non-fatal — tools use
# NODE_EXTRA_CA_CERTS and SSL_CERT_FILE env vars as the primary trust path.
CA_CHAIN="/run/tillandsias/ca-chain.crt"
if [ -f "$CA_CHAIN" ]; then
    if command -v update-ca-trust &>/dev/null; then
        cp "$CA_CHAIN" /etc/pki/ca-trust/source/anchors/tillandsias-ca.crt 2>/dev/null && \
        update-ca-trust 2>/dev/null || true
    elif command -v update-ca-certificates &>/dev/null; then
        cp "$CA_CHAIN" /usr/local/share/ca-certificates/tillandsias-ca.crt 2>/dev/null && \
        update-ca-certificates 2>/dev/null || true
    fi
fi

# @trace spec:forge-welcome
trace_lifecycle "entrypoint" "terminal starting"

# @trace spec:git-mirror-service, spec:forge-offline
# Clone project from git mirror (Phase 3: mirror-only, no direct mount)
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
            # Configure push back to mirror
            # @trace spec:git-mirror-service
            git remote set-url --push origin "git://${TILLANDSIAS_GIT_SERVICE}/${TILLANDSIAS_PROJECT}" 2>/dev/null || true
            # Set git identity from host config
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
        echo "[forge] ERROR: Could not clone project from git service."
        echo "[forge] The git service may not be running. Dropping to shell."
        exec bash
    fi
    echo "[forge] All changes must be committed to persist. Uncommitted work is lost on stop."
fi

# ── OpenSpec (available in maintenance terminals too) ───────
# @trace spec:forge-shell-tools
install_openspec
OS_BIN="$CACHE/openspec/bin/openspec"

# ── Find project directory ──────────────────────────────────
find_project_dir
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── OpenSpec init (every launch, silent) ────────────────────
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ]; then
    "$OS_BIN" init </dev/null >/dev/null 2>&1 || true
fi

# ── Welcome banner ──────────────────────────────────────────
# Use the dedicated welcome script if available (shows mount info, tips).
WELCOME_SCRIPT="/usr/local/share/tillandsias/forge-welcome.sh"
if [ -x "$WELCOME_SCRIPT" ]; then
    "$WELCOME_SCRIPT" || true
else
    show_banner "terminal"
fi

# Prevent fish's config.fish from showing the welcome banner again.
export TILLANDSIAS_WELCOME_SHOWN=1

# ── Launch shell ────────────────────────────────────────────
trace_lifecycle "entrypoint" "terminal launching"
if command -v fish &>/dev/null; then
    trace_lifecycle "exec" "launching fish"
    exec fish
else
    exec bash
fi
