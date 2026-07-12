#!/usr/bin/env bash
# entrypoint-forge-opencode.sh — OpenCode forge entrypoint.
#
# Lifecycle: source common -> install/update OpenCode -> install OpenSpec ->
#            find project -> openspec init -> banner -> exec opencode
#
# Secrets: git identity env only; GitHub token stays in git service.

source /usr/local/lib/tillandsias/lib-common.sh

# @trace gap:ON-008
# Load agent profile configuration from config overlay.
# This exports AGENT_PROFILE, AGENT_SUPPORTS_WEB, and related variables
# based on the user's preferred agent (claude, opencode, opencode-web).
if [ -f /opt/config-overlay/mcp/agent-profile.sh ]; then
    source /opt/config-overlay/mcp/agent-profile.sh
fi

# @trace spec:forge-git-identity-anonymization
# Agent attribution for git commit trailers. These env vars are consumed
# by the prepare-commit-msg hook installed in lib-common.sh.
export TILLANDSIAS_AGENT_NAME="OpenCode"
export TILLANDSIAS_GENERATED_BY="tool=opencode"
export TILLANDSIAS_HOST_KIND="forge"

# @trace spec:simplified-tray-ux
# EXIT trap: pause on error so the popup terminal stays open long enough to
# read the failure. Without this an entrypoint/exec failure closes the window
# instantly (operator repro 2026-07-12: Antigravity lane "crashed right away"
# with no readable error). Mirrors entrypoint-terminal.sh::exit_pause; a
# successful `exec <agent>` replaces the shell, so the trap never fires on
# the happy path.
exit_pause() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ -t 0 ]; then
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "ERROR: forge agent launch failed (exit code: $exit_code)"
        echo "═══════════════════════════════════════════════════════"
        echo ""
        echo "Press any key to exit..."
        read -r -n 1 -s 2>/dev/null || true
    fi
}
trap 'exit_pause' EXIT

# @trace spec:forge-hot-cold-split, spec:agent-cheatsheets, spec:forge-opencode-onboarding
# Populate tmpfs hot mount (/opt/cheatsheets) from image-baked lower layer.
# The --tmpfs mount is already in place (podman establishes it before exec).
populate_hot_paths

# @trace plan/issues/macos-forge-base-build-arch-and-fragility-2026-07-05.md (order 188)
# FIRST_RUN arch-aware prebuilt dev-tools into the persistent cache; backgrounded
# so it never blocks the agent launch, and fail-soft.
ensure_forge_prebuilt_tools >>/tmp/forge-lifecycle.log &
ensure_forge_harnesses >>/tmp/forge-lifecycle.log &

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
        # git uses libcurl, which ignores SSL_CERT_FILE, and the injected
        # gitconfig pins http.sslCAInfo to the enclave-CA-only file — so a
        # git HTTPS fetch to a non-MITMed remote (real GitHub cert chain)
        # fails "unable to get local issuer certificate" (operator repro
        # 2026-07-12: Homebrew install clone). GIT_SSL_CAINFO wins over
        # http.sslCAInfo; point git at the combined bundle.
        export GIT_SSL_CAINFO="$COMBINED"
    fi
fi

# @trace spec:forge-welcome
trace_lifecycle "entrypoint" "opencode starting"

# @trace spec:git-mirror-service, spec:forge-offline, spec:cross-platform, spec:windows-wsl-runtime
# Clone via the shared lib-common::clone_project_from_mirror — supports both
# filesystem (Windows/WSL) and git daemon (Linux/podman) transports with
# wipe-before-clone for re-attach idempotency.
clone_project_from_mirror

# (Inline clone block removed — shared function above replaces it.)

# ── OpenCode + OpenSpec (hard-installed) ───────────────────
# @trace spec:default-image, spec:forge-shell-tools
require_opencode
[ -x "$OC_BIN" ] || harness_missing_fatal opencode
require_openspec
apply_opencode_config_overlay

trace_lifecycle "entrypoint" "opencode ready"

# ── Inference probe (async-inference-launch contract) ───────
# The inference container is started asynchronously off the forge's critical
# path (see spec:async-inference-launch). Probe the endpoint with a short
# timeout; log for accountability but do NOT block — opencode's config.json
# points at http://inference:11434 and opencode itself will surface a clear
# provider error if the user invokes a local-LLM action before inference
# is ready. If the user never uses local inference, it doesn't matter that
# the probe failed.
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
# Always run to ensure /opsx commands are available, even if the project
# was cloned without openspec config. Idempotent — no-ops if already set up.
if [ -x "$OS_BIN" ] && [ -n "$PROJECT_DIR" ]; then
    if ! OS_OUTPUT=$("$OS_BIN" init --tools opencode </dev/null 2>&1); then
        echo "[entrypoint] WARNING: OpenSpec init failed — /opsx commands may not work" >&2
        echo "[entrypoint] $OS_OUTPUT" >&2
    fi
fi

# ── Startup context injection ───────────────────────────────
# @trace spec:project-bootstrap-readme
inject_startup_context "$PROJECT_DIR"

# ── Banner ──────────────────────────────────────────────────
show_banner "opencode"

# ── Synthetic first prompt (startup skill) ─────────────────
# @trace spec:project-bootstrap-readme
# Write a synthetic first message to OpenCode's init-prompt path so the
# routing decision (/startup) is taken inside the OpenCode session.
# This survives OpenCode upgrades and is idempotent across container restarts.
OPENCODE_INIT_PROMPT="/tmp/opencode-init-prompt.txt"
if [ -w "$(dirname "$OPENCODE_INIT_PROMPT")" ]; then
    if [ -n "${TILLANDSIAS_OPENCODE_PROMPT:-}" ]; then
        {
            echo "run /startup"
            printf '\n%s\n' "$TILLANDSIAS_OPENCODE_PROMPT"
        } > "$OPENCODE_INIT_PROMPT"
        trace_lifecycle "startup" "synthetic startup prompt plus optional user prompt written to $OPENCODE_INIT_PROMPT"
    else
        echo "run /startup" > "$OPENCODE_INIT_PROMPT"
        trace_lifecycle "startup" "synthetic first prompt written to $OPENCODE_INIT_PROMPT"
    fi
    export OPENCODE_INIT_PROMPT_FILE="$OPENCODE_INIT_PROMPT"
fi

# ── Launch OpenCode ─────────────────────────────────────────
trace_lifecycle "entrypoint" "opencode launching"

# Detect if `--print` is in the arguments.
IS_DIAGNOSTICS=false
for arg in "$@"; do
    if [ "$arg" = "--print" ]; then
        IS_DIAGNOSTICS=true
    fi
done

if [ -n "${TILLANDSIAS_OPENCODE_PROMPT:-}" ]; then
    trace_lifecycle "exec" "launching prompted opencode run"
    exec "$OC_BIN" run --dangerously-skip-permissions "$TILLANDSIAS_OPENCODE_PROMPT"
elif [ "$IS_DIAGNOSTICS" = "true" ]; then
    trace_lifecycle "exec" "launching unattended opencode run"
    # Execute the unattended loop run command.
    # We ignore the other passed arguments (--print, --output-format, json) as they are intended for the orchestrator,
    # and instead run opencode unattended using the synthetic prompt or command.
    exec "$OC_BIN" run --dangerously-skip-permissions "run /startup"
else
    trace_lifecycle "exec" "launching opencode ($OC_BIN)"
    exec "$OC_BIN" "$@"
fi
