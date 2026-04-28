#!/usr/bin/env bash
# entrypoint-forge-claude.sh — Claude Code forge entrypoint.
#
# Lifecycle: source common -> install/update Claude Code -> install OpenSpec ->
#            find project -> openspec init -> banner -> exec claude
#
# Secrets: gh credentials, git config, claude dir (~/.claude/ mounted from host), cache.

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
    # DISTRO: Fedora path checked first (/etc/pki/), Alpine/Debian fallback (/etc/ssl/)
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

# @trace spec:forge-welcome
trace_lifecycle "entrypoint" "claude-code starting"

# @trace spec:git-mirror-service, spec:forge-offline, spec:cross-platform, spec:windows-wsl-runtime
# Shared dual-transport clone — supports filesystem (Windows/WSL) and git
# daemon (Linux/podman). See lib-common.sh::clone_project_from_mirror.
clone_project_from_mirror

# ── Capture and scrub API key ────────────────────────────────
# Only the agent process that needs it will receive it via exec env.
_CLAUDE_KEY="${ANTHROPIC_API_KEY:-}"
unset ANTHROPIC_API_KEY

# ── Claude Code + OpenSpec (hard-installed) ────────────────
# @trace spec:default-image, spec:forge-shell-tools
require_claude
require_openspec

# ── Credential check ────────────────────────────────────────
if [ -d "$HOME/.claude" ]; then
    local_files="$(ls -1 "$HOME/.claude/" 2>/dev/null | wc -l | tr -d ' ')"
    trace_lifecycle "credentials" "claude: ~/.claude/ mounted ($local_files files)"
else
    trace_lifecycle "credentials" "claude: ~/.claude/ NOT FOUND (first auth will prompt)"
fi

# ── Find project directory ──────────────────────────────────
find_project_dir
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── OpenSpec init (every launch, silent) ────────────────────
# Always run to ensure /opsx commands are available, even if the project
# was cloned without openspec config. Idempotent — no-ops if already set up.
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ]; then
    if ! OS_OUTPUT=$("$OS_BIN" init --tools claude </dev/null 2>&1); then
        echo "[entrypoint] WARNING: OpenSpec init failed — /opsx commands may not work" >&2
        echo "[entrypoint] $OS_OUTPUT" >&2
    fi
fi

# ── Banner ──────────────────────────────────────────────────
show_banner "claude"

# ── Launch Claude Code ──────────────────────────────────────
trace_lifecycle "entrypoint" "claude launching"
trace_lifecycle "exec" "launching claude-code ($CC_BIN)"
exec "$CC_BIN" "$@"
