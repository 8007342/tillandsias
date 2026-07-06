#!/usr/bin/env bash
# entrypoint-forge-codex.sh — Codex code analysis agent forge entrypoint.
#
# Lifecycle: source common -> populate hot paths -> setup CA -> find project -> banner -> exec codex
#
# @trace spec:codex-tray-launcher, spec:forge-hot-cold-split

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
export TILLANDSIAS_AGENT_NAME="OpenAI Codex"
export TILLANDSIAS_GENERATED_BY="tool=codex"
export TILLANDSIAS_HOST_KIND="forge"

# @trace spec:forge-hot-cold-split, spec:agent-cheatsheets
# Populate tmpfs hot mount (/opt/cheatsheets) from image-baked lower layer.
# The --tmpfs mount is already in place (podman establishes it before exec).
populate_hot_paths

# @trace plan/issues/macos-forge-base-build-arch-and-fragility-2026-07-05.md (order 188)
# FIRST_RUN arch-aware prebuilt dev-tools into the persistent cache; backgrounded
# so it never blocks the agent launch, and fail-soft.
ensure_forge_prebuilt_tools &
ensure_forge_harnesses &

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
    fi
fi

# @trace spec:forge-welcome
trace_lifecycle "entrypoint" "codex starting"

# @trace spec:git-mirror-service, spec:forge-offline, spec:cross-platform, spec:windows-wsl-runtime
# Shared dual-transport clone — supports filesystem (Windows/WSL) and git
# daemon (Linux/podman). See lib-common.sh::clone_project_from_mirror.
clone_project_from_mirror

# ── SSH key auto-discovery ──────────────────────────────────
# @trace gap:ON-007
# Automatically discover and export SSH keys/agent from the host.
# This enables SSH-based git operations without manual configuration.
export_ssh_env || true

# ── Find project directory ──────────────────────────────────
find_project_dir
[ -n "$PROJECT_DIR" ] && cd "$PROJECT_DIR"
configure_git_identity
trace_lifecycle "project" "dir=${PROJECT_DIR:-<none>}"

# ── Startup context injection ───────────────────────────────
# @trace spec:project-bootstrap-readme
inject_startup_context "$PROJECT_DIR"

# ── Agent binary (EVERY_LAUNCH install/update) ─────────────
# @trace plan/issues/forge-harness-every-launch-latest-2026-07-04.md (order 181)
require_codex

# ── Banner ──────────────────────────────────────────────────
show_banner "codex"

# ── Launch Codex ────────────────────────────────────────────
# @trace plan/issues/codex-forge-yolo-defaults-2026-07-04.md (order 171)
# Full-auto inside the forge. The forge container IS the containment boundary
# (--cap-drop=ALL, --security-opt=no-new-privileges, --userns=keep-id,
# proxy-only egress on the --internal enclave network), so Codex's own approval
# prompts and inner seccomp/landlock sandbox add no meaningful security — they
# only stall unattended /meta-orchestration loops and (because the default inner
# sandbox can restrict egress) can block the agent's own network calls.
# `--dangerously-bypass-approvals-and-sandbox` is documented by Codex 0.137.0 as
# "intended solely for running in environments that are externally sandboxed",
# which is exactly this forge. Gated on TILLANDSIAS_HOST_KIND=forge so it can
# only ever engage inside the forge; a non-forge invocation keeps Codex's normal
# approval/sandbox posture. Does NOT weaken the host credential boundary (that is
# the source-mount quarantine, order 170) — it governs command execution and the
# inner sandbox only.
codex_forge_args=()
if [ "${TILLANDSIAS_HOST_KIND:-}" = "forge" ]; then
    codex_forge_args+=(--dangerously-bypass-approvals-and-sandbox)
fi
trace_lifecycle "entrypoint" "codex launching"
trace_lifecycle "exec" "launching codex"
exec codex "${codex_forge_args[@]}" "$@"
