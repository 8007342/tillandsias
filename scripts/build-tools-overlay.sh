#!/usr/bin/env bash
# build-tools-overlay.sh — Populate a tools overlay directory using a temporary
# forge container.
#
# Usage: scripts/build-tools-overlay.sh <output-dir> [<forge-image>]
#
# Installs Claude Code, OpenSpec, and OpenCode into subdirectories of
# <output-dir>. The output dir is mounted at /home/forge/.tools inside the
# builder container so that npm records the correct absolute paths in its
# .bin/ wrapper scripts. When the overlay is later mounted read-only into
# forge containers at the same path, the binaries resolve their dependencies
# without modification.
#
# If <forge-image> is omitted, the script detects the latest
# tillandsias-forge image tag from podman. Falls back to
# tillandsias-forge:latest if no versioned tag is found.
#
# Environment:
#   PODMAN_PATH          Override podman binary location
#   TOOLS_OVERLAY_QUIET  Suppress progress output (for background rebuilds)

set -euo pipefail

# @trace spec:layered-tools-overlay

# ---------------------------------------------------------------------------
# macOS PATH fix: Finder-launched apps don't inherit shell PATH.
# Ensure common tool directories are reachable (Homebrew, MacPorts, etc.)
# Linux is unaffected — this block is a no-op there.
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" == "Darwin" ]]; then
    for _dir in /opt/homebrew/bin /opt/local/bin /usr/local/bin; do
        [[ -d "$_dir" ]] && [[ ":$PATH:" != *":$_dir:"* ]] && export PATH="$_dir:$PATH"
    done
    unset _dir
fi

# ---------------------------------------------------------------------------
# Resolve the podman binary: prefer PODMAN_PATH from Rust caller, then
# check known absolute paths, then fall back to bare "podman" (PATH lookup).
# ---------------------------------------------------------------------------
if [[ -n "${PODMAN_PATH:-}" ]] && [[ -x "$PODMAN_PATH" ]]; then
    PODMAN="$PODMAN_PATH"
elif [[ -x /opt/homebrew/bin/podman ]]; then
    PODMAN=/opt/homebrew/bin/podman
elif [[ -x /opt/local/bin/podman ]]; then
    PODMAN=/opt/local/bin/podman
elif [[ -x /usr/local/bin/podman ]]; then
    PODMAN=/usr/local/bin/podman
elif [[ -x /usr/bin/podman ]]; then
    PODMAN=/usr/bin/podman
else
    PODMAN=podman
fi

# ---------------------------------------------------------------------------
# Colors and output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

_info()  { [[ -n "${TOOLS_OVERLAY_QUIET:-}" ]] || echo -e "${GREEN}[tools-overlay]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[tools-overlay]${NC} $*"; }
_error() { echo -e "${RED}[tools-overlay]${NC} $*" >&2; }
_step()  { [[ -n "${TOOLS_OVERLAY_QUIET:-}" ]] || echo -e "${CYAN}[tools-overlay]${NC} $*"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    echo "Usage: build-tools-overlay.sh <output-dir> [<forge-image>]"
    echo ""
    echo "Populate a tools overlay directory with Claude Code, OpenCode, and OpenSpec."
    echo ""
    echo "Arguments:"
    echo "  <output-dir>     Directory to install tools into (created if missing)"
    echo "  <forge-image>    Forge image to use (default: auto-detect latest tag)"
    echo ""
    echo "Environment:"
    echo "  PODMAN_PATH          Override podman binary location"
    echo "  TOOLS_OVERLAY_QUIET  Suppress progress output"
    exit 0
fi

OUTPUT_DIR="$1"

# ---------------------------------------------------------------------------
# Auto-detect forge image if not provided
# ---------------------------------------------------------------------------
# @trace spec:layered-tools-overlay, spec:default-image
if [[ -n "${2:-}" ]]; then
    FORGE_IMAGE="$2"
else
    # Find the latest versioned tillandsias-forge image by sorting tags.
    # The Rust app uses `tillandsias-forge:v<FULL_VERSION>` (e.g., v0.1.127.148).
    FORGE_IMAGE="$("$PODMAN" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
        | grep '^tillandsias-forge:v' \
        | sort -t'v' -k2 -V \
        | tail -1 || true)"

    if [[ -z "$FORGE_IMAGE" ]]; then
        # No versioned tag — try :latest
        if "$PODMAN" image exists tillandsias-forge:latest 2>/dev/null; then
            FORGE_IMAGE="tillandsias-forge:latest"
        else
            _error "No tillandsias-forge image found. Build one first:"
            _error "  scripts/build-image.sh forge"
            exit 1
        fi
    fi
fi

# Verify the image exists
if ! "$PODMAN" image exists "$FORGE_IMAGE" 2>/dev/null; then
    _error "Image ${FORGE_IMAGE} not found. Build it first:"
    _error "  scripts/build-image.sh forge --tag ${FORGE_IMAGE}"
    exit 1
fi

_step "Building tools overlay into ${BOLD}${OUTPUT_DIR}${NC}"
_info "Using forge image: ${BOLD}${FORGE_IMAGE}${NC}"

# ---------------------------------------------------------------------------
# Prepare output directory
# ---------------------------------------------------------------------------
mkdir -p "$OUTPUT_DIR"/{claude,opencode,openspec}

# ---------------------------------------------------------------------------
# Network detection — use enclave proxy if available
# ---------------------------------------------------------------------------
# @trace spec:proxy-container, spec:layered-tools-overlay
PROXY_ARGS=()
if "$PODMAN" network exists tillandsias-enclave 2>/dev/null; then
    _info "Enclave network detected, routing through proxy"
    PROXY_ARGS=(
        --network=tillandsias-enclave
        -e HTTP_PROXY=http://proxy:3128
        -e HTTPS_PROXY=http://proxy:3128
        -e http_proxy=http://proxy:3128
        -e https_proxy=http://proxy:3128
    )

    # Mount the ephemeral CA chain so HTTPS through the MITM proxy is trusted.
    # CA_CHAIN_PATH is set by the Rust caller (tools_overlay.rs).
    # @trace spec:proxy-container, spec:layered-tools-overlay
    if [[ -n "${CA_CHAIN_PATH:-}" ]] && [[ -f "$CA_CHAIN_PATH" ]]; then
        _info "Mounting CA chain for proxy trust"
        PROXY_ARGS+=(
            -v "${CA_CHAIN_PATH}:/run/tillandsias/ca-chain.crt:ro"
            -e NODE_EXTRA_CA_CERTS=/run/tillandsias/ca-chain.crt
            -e SSL_CERT_FILE=/run/tillandsias/ca-chain.crt
            -e REQUESTS_CA_BUNDLE=/run/tillandsias/ca-chain.crt
        )
    else
        _warn "No CA chain found — HTTPS through proxy may fail"
    fi
fi

# ---------------------------------------------------------------------------
# Install all tools in a single container run
# ---------------------------------------------------------------------------
# The mount path MUST be /home/forge/.tools — matching the mount path in forge
# containers. npm records absolute paths in .bin/ wrapper scripts; if they
# don't match, the binaries won't work when mounted read-only in forge.
#
# Security flags match the forge container profile:
#   --rm            Ephemeral — no leftover containers
#   --init          Clean PID 1 (reap zombies)
#   --cap-drop=ALL  No Linux capabilities
#   --security-opt=no-new-privileges  No privilege escalation
#   --userns=keep-id  UID mapping for bind-mount permissions
#   --security-opt=label=disable  Allow bind-mount on SELinux hosts
# @trace spec:layered-tools-overlay

BUILD_START="$(date +%s)"

_step "Installing Claude Code..."

"$PODMAN" run --rm --init \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --userns=keep-id \
    --security-opt=label=disable \
    "${PROXY_ARGS[@]}" \
    -v "$OUTPUT_DIR:/home/forge/.tools:rw" \
    --entrypoint bash \
    "$FORGE_IMAGE" \
    -c '
        set -euo pipefail

        echo "[tools-overlay] Installing Claude Code..."
        npm install -g --prefix /home/forge/.tools/claude @anthropic-ai/claude-code 2>&1

        echo "[tools-overlay] Installing OpenSpec..."
        npm install -g --prefix /home/forge/.tools/openspec @fission-ai/openspec 2>&1

        echo "[tools-overlay] Installing OpenCode..."
        # The curl installer may ignore OPENCODE_INSTALL_DIR, so we handle
        # both cases: direct install to the target dir, or relocate afterward.
        export OPENCODE_INSTALL_DIR=/home/forge/.tools/opencode
        mkdir -p /home/forge/.tools/opencode/bin
        set +e
        OC_OUTPUT=$(curl -fsSL https://opencode.ai/install | bash 2>&1)
        OC_EXIT=$?
        set -e
        if [ $OC_EXIT -ne 0 ]; then
            echo "[tools-overlay] WARNING: OpenCode installer exited with code $OC_EXIT" >&2
            echo "[tools-overlay] $OC_OUTPUT" >&2
        fi

        # If installer ignored OPENCODE_INSTALL_DIR (common), relocate binary
        if [ ! -x /home/forge/.tools/opencode/bin/opencode ] && [ -f "$HOME/.opencode/bin/opencode" ]; then
            cp "$HOME/.opencode/bin/opencode" /home/forge/.tools/opencode/bin/opencode
            chmod +x /home/forge/.tools/opencode/bin/opencode
        fi

        # Verify installations
        FAILURES=0
        if [ -x /home/forge/.tools/claude/bin/claude ]; then
            echo "[tools-overlay] Claude Code: OK"
        else
            echo "[tools-overlay] Claude Code: FAILED (binary not found)" >&2
            FAILURES=$((FAILURES + 1))
        fi

        if [ -x /home/forge/.tools/openspec/bin/openspec ]; then
            echo "[tools-overlay] OpenSpec: OK"
        else
            echo "[tools-overlay] OpenSpec: FAILED (binary not found)" >&2
            FAILURES=$((FAILURES + 1))
        fi

        if [ -x /home/forge/.tools/opencode/bin/opencode ]; then
            echo "[tools-overlay] OpenCode: OK"
        else
            echo "[tools-overlay] OpenCode: FAILED (binary not found)" >&2
            FAILURES=$((FAILURES + 1))
        fi

        if [ "$FAILURES" -gt 0 ]; then
            echo "[tools-overlay] $FAILURES tool(s) failed to install" >&2
            exit 1
        fi

        echo "[tools-overlay] All tools installed successfully"
    '

RC=$?
BUILD_END="$(date +%s)"
BUILD_DURATION=$(( BUILD_END - BUILD_START ))

if [[ $RC -ne 0 ]]; then
    _error "Builder container failed (exit code $RC)"
    exit $RC
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
_info "----------------------------------------------"
_info "Output:   ${BOLD}${OUTPUT_DIR}${NC}"
_info "Image:    ${FORGE_IMAGE}"
_info "Time:     ${BUILD_DURATION}s"
_info "----------------------------------------------"

exit 0
