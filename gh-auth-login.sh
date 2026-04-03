#!/usr/bin/env bash
# =============================================================================
# gh-auth-login.sh — GitHub authentication for Tillandsias
#
# @trace spec:secret-management, spec:native-secrets-store
#
# Strategy (in priority order):
#   1. If `gh` is installed on the HOST, use it directly.
#      Token is stored in the host's native OS keyring by `gh` (v2.40+).
#      No plaintext files. No container needed.
#
#   2. If `gh` is NOT on the host, run it in a forge container with the
#      host's D-Bus session bus forwarded. `gh` writes to the host keyring
#      through the socket. Token never touches disk.
#
#   3. If D-Bus is unavailable (headless, SSH), fall back to `gh` in the
#      forge container with hosts.yml bind-mounted. Token is written to
#      disk as plaintext — `--log-secret-management` traces this.
#
# Credentials persist in:
#   Token:    OS native keyring (service=gh:github.com, account=<username>)
#   Metadata: ~/.cache/tillandsias/secrets/gh/hosts.yml (protocol, user list)
#   Identity: ~/.cache/tillandsias/secrets/git/.gitconfig (name, email)
#
# Usage:
#   ./gh-auth-login.sh            # Run interactive authentication
#   ./gh-auth-login.sh --status   # Check if credentials are configured
#   ./gh-auth-login.sh --help     # Show usage
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Versioned tag passed by the Tillandsias binary; no :latest fallback.
FORGE_IMAGE="${FORGE_IMAGE_TAG:?FORGE_IMAGE_TAG must be set by the caller}"

# Clean AppImage environment — LD_LIBRARY_PATH/LD_PRELOAD break podman
# @trace spec:secret-management
unset LD_LIBRARY_PATH LD_PRELOAD

# Find podman — prefer PODMAN_PATH (set by Tillandsias binary), then search PATH
if [[ -n "${PODMAN_PATH:-}" ]] && [[ -x "$PODMAN_PATH" ]]; then
    PODMAN="$PODMAN_PATH"
else
    PODMAN="podman"
    for p in /usr/bin/podman /usr/local/bin/podman /bin/podman; do
        [ -x "$p" ] && PODMAN="$p" && break
    done
fi
if [[ "$(uname -s)" == "Darwin" ]]; then
    CACHE_DIR="$HOME/Library/Caches/tillandsias"
else
    CACHE_DIR="$HOME/.cache/tillandsias"
fi
SECRETS_DIR="${CACHE_DIR}/secrets"
GH_DIR="${SECRETS_DIR}/gh"
GIT_DIR="${SECRETS_DIR}/git"
GH_HOSTS="${GH_DIR}/hosts.yml"
GITCONFIG="${GIT_DIR}/.gitconfig"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[gh-auth]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[gh-auth]${NC} $*"; }
_error() { echo -e "${RED}[gh-auth]${NC} $*" >&2; }
_trace() { echo -e "${DIM}[gh-auth] @trace spec:secret-management — $*${NC}"; }

# ---------------------------------------------------------------------------
# Host tool detection
# @trace spec:secret-management
# ---------------------------------------------------------------------------
HOST_GH=""
for p in gh /usr/bin/gh /usr/local/bin/gh "$HOME/.local/bin/gh"; do
    if command -v "$p" &>/dev/null 2>&1 || [[ -x "$p" ]]; then
        HOST_GH="$p"
        break
    fi
done

# D-Bus session bus availability (required for keyring access from containers)
DBUS_AVAILABLE=false
if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    # Extract socket path from address
    DBUS_SOCKET="${DBUS_SESSION_BUS_ADDRESS#unix:path=}"
    if [[ -S "$DBUS_SOCKET" ]]; then
        DBUS_AVAILABLE=true
    fi
fi

# ---------------------------------------------------------------------------
# --help
# ---------------------------------------------------------------------------
show_help() {
    cat <<'EOF'
gh-auth-login.sh — GitHub authentication for Tillandsias

Authenticates with GitHub and stores the token in your OS keyring.
No passwords are written to disk.

USAGE:
    ./gh-auth-login.sh              Run interactive authentication
    ./gh-auth-login.sh --status     Check if credentials are configured
    ./gh-auth-login.sh --help       Show this help

WHAT IT DOES:
    1. Prompts for your name and email (for git commits)
    2. Runs `gh auth login` (token stored in OS keyring)
    3. Runs `gh auth setup-git` (configures git credential helper)

HOW CREDENTIALS ARE STORED:
    Token:    OS native keyring (never written to disk)
    Metadata: ~/.cache/tillandsias/secrets/gh/hosts.yml (protocol only)
    Identity: ~/.cache/tillandsias/secrets/git/.gitconfig (name, email)

DETECTION PRIORITY:
    1. Host `gh` CLI — token stored directly in OS keyring
    2. Forge container + D-Bus forwarding — token stored in host keyring
    3. Forge container + hosts.yml fallback — plaintext (if no D-Bus)

Use `tillandsias --log-secret-management` to trace credential operations.
EOF
}

# ---------------------------------------------------------------------------
# --status
# @trace spec:secret-management
# ---------------------------------------------------------------------------
show_status() {
    echo ""
    echo "GitHub Authentication Status"
    echo "============================"
    echo ""

    # Check via host gh first (most authoritative)
    if [[ -n "$HOST_GH" ]]; then
        if "$HOST_GH" auth status &>/dev/null 2>&1; then
            local gh_user
            gh_user=$("$HOST_GH" auth status 2>&1 | grep -oP 'Logged in to github.com account \K\S+' || echo "")
            if [[ -n "$gh_user" ]]; then
                echo -e "  GitHub CLI:   ${GREEN}Authenticated as ${gh_user}${NC} (host gh, OS keyring)"
            else
                echo -e "  GitHub CLI:   ${GREEN}Authenticated${NC} (host gh, OS keyring)"
            fi
        else
            echo -e "  GitHub CLI:   ${RED}Not authenticated${NC} (host gh found but not logged in)"
        fi
    elif [[ -f "$GH_HOSTS" ]] && [[ -s "$GH_HOSTS" ]]; then
        echo -e "  GitHub CLI:   ${YELLOW}Configured${NC} ($GH_HOSTS)"
        echo -e "                ${DIM}(metadata file — token in OS keyring or plaintext fallback)${NC}"
    else
        echo -e "  GitHub CLI:   ${RED}Not configured${NC}"
    fi

    # Check git identity
    if [[ -f "$GITCONFIG" ]] && [[ -s "$GITCONFIG" ]]; then
        local name email
        name=$(grep -oP 'name\s*=\s*\K.*' "$GITCONFIG" 2>/dev/null || echo "")
        email=$(grep -oP 'email\s*=\s*\K.*' "$GITCONFIG" 2>/dev/null || echo "")
        if [[ -n "$name" ]] && [[ -n "$email" ]]; then
            echo -e "  Git identity: ${GREEN}${name} <${email}>${NC}"
        else
            echo -e "  Git identity: ${YELLOW}Partially configured${NC} ($GITCONFIG)"
        fi
    else
        echo -e "  Git identity: ${RED}Not configured${NC}"
    fi

    # Show detection info
    echo ""
    echo -e "  ${DIM}Detection:${NC}"
    if [[ -n "$HOST_GH" ]]; then
        echo -e "    ${GREEN}gh CLI:${NC}  $HOST_GH (host-native)"
    else
        echo -e "    ${YELLOW}gh CLI:${NC}  not found on host (will use forge container)"
    fi
    if [[ "$DBUS_AVAILABLE" == true ]]; then
        echo -e "    ${GREEN}D-Bus:${NC}   available ($DBUS_SESSION_BUS_ADDRESS)"
    else
        echo -e "    ${YELLOW}D-Bus:${NC}   not available (plaintext fallback if container mode)"
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# Flag parsing
# ---------------------------------------------------------------------------
case "${1:-}" in
    --help|-h)
        show_help
        exit 0
        ;;
    --status)
        show_status
        exit 0
        ;;
    "")
        # Default: run auth flow
        ;;
    *)
        _error "Unknown flag: $1 (try --help)"
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Ensure secrets directories exist
# ---------------------------------------------------------------------------
mkdir -p "$GH_DIR" "$GIT_DIR"
[[ -f "$GITCONFIG" ]] || touch "$GITCONFIG"

# ---------------------------------------------------------------------------
# Check for existing credentials
# @trace spec:secret-management
# ---------------------------------------------------------------------------
ALREADY_AUTHED=false
if [[ -n "$HOST_GH" ]] && "$HOST_GH" auth status &>/dev/null 2>&1; then
    ALREADY_AUTHED=true
    _warn "GitHub credentials already exist (in OS keyring)."
elif [[ -f "$GH_HOSTS" ]] && [[ -s "$GH_HOSTS" ]]; then
    ALREADY_AUTHED=true
    _warn "GitHub credentials already exist (hosts.yml)."
fi

if [[ "$ALREADY_AUTHED" == true ]]; then
    show_status
    read -rp "Re-authenticate? [y/N] " answer
    case "${answer:-n}" in
        [Yy])
            _info "Clearing old credentials before re-authentication..."
            rm -f "$GH_HOSTS"
            # If host gh exists, logout to clear keyring entry too
            if [[ -n "$HOST_GH" ]]; then
                "$HOST_GH" auth logout --hostname github.com 2>/dev/null || true
                _trace "Cleared gh keyring entry via 'gh auth logout'"
            fi
            ;;
        *)
            _info "Keeping existing credentials."
            exit 0
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Prompt for git identity (always on host side — simpler TTY handling)
# ---------------------------------------------------------------------------
echo ""
echo "=== GitHub Login ==="
echo ""

# Pre-fill from existing gitconfig if available
EXISTING_NAME=$(grep -oP 'name\s*=\s*\K.*' "$GITCONFIG" 2>/dev/null || echo "")
EXISTING_EMAIL=$(grep -oP 'email\s*=\s*\K.*' "$GITCONFIG" 2>/dev/null || echo "")

if [[ -n "$EXISTING_NAME" ]]; then
    read -rp "Your name (for git commits) [$EXISTING_NAME]: " GIT_NAME
    GIT_NAME="${GIT_NAME:-$EXISTING_NAME}"
else
    read -rp "Your name (for git commits): " GIT_NAME
fi

if [[ -n "$EXISTING_EMAIL" ]]; then
    read -rp "Your email (for git commits) [$EXISTING_EMAIL]: " GIT_EMAIL
    GIT_EMAIL="${GIT_EMAIL:-$EXISTING_EMAIL}"
else
    read -rp "Your email (for git commits): " GIT_EMAIL
fi

if [[ -z "$GIT_NAME" ]] || [[ -z "$GIT_EMAIL" ]]; then
    _error "Name and email are required."
    exit 1
fi

mkdir -p "$GIT_DIR"
git config --file "$GIT_DIR/.gitconfig" user.name "$GIT_NAME"
git config --file "$GIT_DIR/.gitconfig" user.email "$GIT_EMAIL"
_info "Git identity saved: $GIT_NAME <$GIT_EMAIL>"

# ---------------------------------------------------------------------------
# Strategy 1: Host-native gh CLI
# @trace spec:secret-management
# ---------------------------------------------------------------------------
if [[ -n "$HOST_GH" ]]; then
    _info "Using host gh CLI: $HOST_GH"
    _trace "Token will be stored in OS native keyring by gh (v2.40+ default)"
    echo ""

    # gh auth login on the host — stores directly in OS keyring
    # GH_CONFIG_DIR points gh to our managed config directory so hosts.yml
    # metadata (protocol, user list) lands in our secrets dir, not ~/.config/gh
    GH_CONFIG_DIR="$GH_DIR" "$HOST_GH" auth login --git-protocol https

    # Setup git credential helper
    GH_CONFIG_DIR="$GH_DIR" "$HOST_GH" auth setup-git 2>/dev/null || true

    echo ""
    _info "Authentication complete — token stored in OS keyring."
    _trace "No plaintext token on disk. hosts.yml contains metadata only (protocol, username)."
    show_status
    echo ""
    read -rp "Press Enter to close..." _
    exit 0
fi

# ---------------------------------------------------------------------------
# Strategy 2 & 3: Forge container (with or without D-Bus)
# @trace spec:secret-management
# ---------------------------------------------------------------------------

# Ensure forge image exists
if ! $PODMAN image exists "$FORGE_IMAGE" 2>/dev/null; then
    # The tray app builds the image before launching this script, so if we
    # get here something went wrong. Try common locations for build-image.sh.
    _warn "Forge image not found: $FORGE_IMAGE"
    echo ""

    BUILD_SCRIPT=""
    # 1. Embedded temp dir (launched from tray app)
    for candidate in \
        "$SCRIPT_DIR/scripts/build-image.sh" \
        "$SCRIPT_DIR/../image-sources/scripts/build-image.sh" \
        ; do
        [[ -x "$candidate" ]] && BUILD_SCRIPT="$candidate" && break
    done
    # 2. Installed data location
    if [[ -z "$BUILD_SCRIPT" ]]; then
        if [[ "$(uname -s)" == "Darwin" ]]; then
            DATA_DIR="${HOME}/Library/Application Support/tillandsias"
        else
            DATA_DIR="${HOME}/.local/share/tillandsias"
        fi
        [[ -x "$DATA_DIR/scripts/build-image.sh" ]] && BUILD_SCRIPT="$DATA_DIR/scripts/build-image.sh"
    fi

    if [[ -n "$BUILD_SCRIPT" ]]; then
        read -rp "Build it now? [Y/n] " answer
        case "${answer:-y}" in
            [Yy]|"")
                _info "Building forge image..."
                "$BUILD_SCRIPT" forge
                echo ""
                ;;
            *)
                _error "Cannot proceed without forge image."
                exit 1
                ;;
        esac
    else
        _error "Forge image missing. Restart the app — it builds the image automatically."
        exit 1
    fi

    if ! $PODMAN image exists "$FORGE_IMAGE" 2>/dev/null; then
        _error "Image still not available after build."
        exit 1
    fi
fi

# Build common podman security flags
# @trace spec:podman-orchestration
SECURITY_FLAGS=(
    --cap-drop=ALL
    --security-opt=no-new-privileges
    --userns=keep-id
    --security-opt=label=disable
)

# Build D-Bus forwarding flags if available
# @trace spec:secret-management
DBUS_FLAGS=()
if [[ "$DBUS_AVAILABLE" == true ]]; then
    _info "Using forge container with D-Bus forwarding"
    _trace "D-Bus socket forwarded — gh will store token in host OS keyring"
    _trace "Socket: $DBUS_SOCKET (read-only mount, auth container only)"

    DBUS_FLAGS=(
        -v "${DBUS_SOCKET}:${DBUS_SOCKET}:ro"
        -e "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS}"
        -e "XDG_RUNTIME_DIR=/run/user/$(id -u)"
    )
    # Also mount the XDG_RUNTIME_DIR so the socket path resolves inside container
    if [[ -d "/run/user/$(id -u)" ]]; then
        DBUS_FLAGS+=(-v "/run/user/$(id -u):/run/user/$(id -u):ro")
    fi
else
    _warn "D-Bus not available — using plaintext hosts.yml fallback"
    _trace "Token will be written to $GH_HOSTS (plaintext on disk)"
    _trace "Run 'tillandsias --log-secret-management' to trace credential lifecycle"
fi

echo ""
_info "Starting GitHub authentication..."
_info "(You'll be prompted to paste a GitHub token)"
echo ""

# Run gh auth login in forge container
# --entrypoint "" clears the image default, then the command IS the entrypoint.
$PODMAN run -it --rm --init \
    --name tillandsias-gh-login \
    "${SECURITY_FLAGS[@]}" \
    "${DBUS_FLAGS[@]}" \
    --entrypoint "" \
    -e GIT_CONFIG_GLOBAL=/home/forge/.config/tillandsias-git/.gitconfig \
    -v "${GH_DIR}:/home/forge/.config/gh" \
    -v "${GIT_DIR}:/home/forge/.config/tillandsias-git:rw" \
    "$FORGE_IMAGE" \
    gh auth login --git-protocol https

# Run setup-git in a separate non-interactive container
$PODMAN run --rm --init \
    "${SECURITY_FLAGS[@]}" \
    "${DBUS_FLAGS[@]}" \
    --entrypoint "" \
    -e GIT_CONFIG_GLOBAL=/home/forge/.config/tillandsias-git/.gitconfig \
    -v "${GH_DIR}:/home/forge/.config/gh" \
    -v "${GIT_DIR}:/home/forge/.config/tillandsias-git" \
    "$FORGE_IMAGE" \
    gh auth setup-git 2>/dev/null || true

echo ""
if [[ "$DBUS_AVAILABLE" == true ]]; then
    _info "Authentication complete — token stored in OS keyring via D-Bus."
    _trace "hosts.yml contains metadata only (protocol, username). No token on disk."
else
    _warn "Authentication complete — token stored in hosts.yml (plaintext)."
    _trace "Tillandsias will migrate this to the OS keyring on next launch."
    _trace "See: tillandsias --log-secret-management"
fi
show_status
echo ""
read -rp "Press Enter to close..." _
