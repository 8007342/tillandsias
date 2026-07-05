#!/usr/bin/env bash
# entrypoint-forge-antigravity.sh — Antigravity agent forge entrypoint.
#
# Lifecycle: source common -> populate hot paths -> setup CA -> find project -> banner -> exec agy
#
# @trace spec:forge-hot-cold-split

source /usr/local/lib/tillandsias/lib-common.sh

# @trace gap:ON-008
# Load agent profile configuration from config overlay.
if [ -f /opt/config-overlay/mcp/agent-profile.sh ]; then
    source /opt/config-overlay/mcp/agent-profile.sh
fi

# @trace spec:forge-git-identity-anonymization
# Agent attribution for git commit trailers.
export TILLANDSIAS_AGENT_NAME="Google Antigravity"
export TILLANDSIAS_GENERATED_BY="tool=antigravity"
export TILLANDSIAS_HOST_KIND="forge"

# @trace spec:forge-hot-cold-split, spec:agent-cheatsheets
# Populate tmpfs hot mount (/opt/cheatsheets) from image-baked lower layer.
# The --tmpfs mount is already in place (podman establishes it before exec).
populate_hot_paths

# @trace plan/issues/macos-forge-base-build-arch-and-fragility-2026-07-05.md (order 188)
# FIRST_RUN arch-aware prebuilt dev-tools into the persistent cache; backgrounded
# so it never blocks the agent launch, and fail-soft.
ensure_forge_prebuilt_tools &

# @trace spec:proxy-container
# Trust the Tillandsias enclave CA chain for HTTPS proxy caching.
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
    fi
fi

# @trace spec:forge-welcome
trace_lifecycle "entrypoint" "antigravity starting"

# @trace spec:git-mirror-service, spec:forge-offline, spec:cross-platform, spec:windows-wsl-runtime
clone_project_from_mirror

# ── SSH key auto-discovery ──────────────────────────────────
# @trace gap:ON-007
export_ssh_env || true

# ── Find project directory ──────────────────────────────────
find_project_dir
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
configure_git_identity
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── Startup context injection ───────────────────────────────
# @trace spec:project-bootstrap-readme
inject_startup_context "$PROJECT_DIR"

# ── Banner ──────────────────────────────────────────────────
show_banner "antigravity"

# ── Ensure the Antigravity CLI (agy) — EVERY_LAUNCH, latest ─────
# @trace plan/issues/forge-harness-every-launch-latest-2026-07-04.md (order 181)
# Installed at launch (not baked): download the official installer WITH A TIMEOUT
# then run it (NOT a `curl | bash` pipe — that pipes an unbounded fetch straight to
# a shell). Fail-soft: if the install fails, exec below surfaces a clear error.
if ! command -v agy >/dev/null 2>&1; then
    trace_lifecycle "tools" "installing Antigravity CLI (agy) at launch"
    _agy_installer="$(mktemp 2>/dev/null)"
    if [ -n "$_agy_installer" ] && curl -fsSL --max-time 90 https://antigravity.google/cli/install.sh -o "$_agy_installer" 2>/dev/null; then
        ANTIGRAVITY_BIN="/usr/local/bin/agy" bash "$_agy_installer" 2>/dev/null \
            || trace_lifecycle "tools" "agy install failed (non-fatal)"
    else
        trace_lifecycle "tools" "agy installer fetch failed (non-fatal)"
    fi
    rm -f "$_agy_installer" 2>/dev/null || true
fi

# ── Launch Antigravity ──────────────────────────────────────
trace_lifecycle "entrypoint" "antigravity launching"
trace_lifecycle "exec" "launching agy"
exec agy "$@"
