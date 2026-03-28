#!/usr/bin/env bash
# =============================================================================
# gh-auth-login.sh — GitHub authentication via forge container
#
# Runs `gh auth login` and git identity setup inside a forge container
# with full interactive TTY. Credentials persist at:
#   ~/.cache/tillandsias/secrets/gh/hosts.yml   (GitHub CLI)
#   ~/.cache/tillandsias/secrets/git/.gitconfig  (Git identity)
#
# Usage:
#   ./gh-auth-login.sh            # Run interactive authentication
#   ./gh-auth-login.sh --status   # Check if credentials are configured
#   ./gh-auth-login.sh --help     # Show usage
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_IMAGE="tillandsias-forge:latest"

# Find podman — AppImages may not have /usr/bin in PATH
PODMAN="podman"
for p in /usr/bin/podman /usr/local/bin/podman /bin/podman; do
    [ -x "$p" ] && PODMAN="$p" && break
done
CACHE_DIR="${HOME}/.cache/tillandsias"
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
NC='\033[0m'

_info()  { echo -e "${GREEN}[gh-auth]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[gh-auth]${NC} $*"; }
_error() { echo -e "${RED}[gh-auth]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# --help
# ---------------------------------------------------------------------------
show_help() {
    cat <<'EOF'
gh-auth-login.sh — GitHub authentication for Tillandsias

Runs `gh auth login` and git identity setup inside a forge container.
Credentials are saved locally and shared with all Tillandsias environments.

USAGE:
    ./gh-auth-login.sh              Run interactive authentication
    ./gh-auth-login.sh --status     Check if credentials are configured
    ./gh-auth-login.sh --help       Show this help

WHAT IT DOES:
    1. Prompts for your name and email (for git commits)
    2. Runs `gh auth login` (GitHub CLI authentication)
    3. Runs `gh auth setup-git` (configures git to use GitHub credentials)

CREDENTIALS ARE STORED AT:
    ~/.cache/tillandsias/secrets/gh/       GitHub CLI credentials
    ~/.cache/tillandsias/secrets/git/      Git identity (.gitconfig)
EOF
}

# ---------------------------------------------------------------------------
# --status
# ---------------------------------------------------------------------------
show_status() {
    echo ""
    echo "GitHub Authentication Status"
    echo "============================"
    echo ""

    # Check GitHub CLI credentials
    if [[ -f "$GH_HOSTS" ]] && [[ -s "$GH_HOSTS" ]]; then
        echo -e "  GitHub CLI:  ${GREEN}Configured${NC} ($GH_HOSTS)"
    else
        echo -e "  GitHub CLI:  ${RED}Not configured${NC}"
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
# Check forge image
# ---------------------------------------------------------------------------
if ! $PODMAN image exists "$FORGE_IMAGE" 2>/dev/null; then
    _warn "Forge image not found: $FORGE_IMAGE"
    echo ""
    if [[ -x "$SCRIPT_DIR/scripts/build-image.sh" ]]; then
        read -rp "Build it now? [Y/n] " answer
        case "${answer:-y}" in
            [Yy]|"")
                _info "Building forge image..."
                "$SCRIPT_DIR/scripts/build-image.sh" forge
                echo ""
                ;;
            *)
                _error "Cannot proceed without forge image."
                exit 1
                ;;
        esac
    else
        # Check installed location
        DATA_DIR="${HOME}/.local/share/tillandsias"
        if [[ -x "$DATA_DIR/scripts/build-image.sh" ]]; then
            read -rp "Build it now? [Y/n] " answer
            case "${answer:-y}" in
                [Yy]|"")
                    _info "Building forge image..."
                    "$DATA_DIR/scripts/build-image.sh" forge
                    echo ""
                    ;;
                *)
                    _error "Cannot proceed without forge image."
                    exit 1
                    ;;
            esac
        else
            _error "Cannot find build-image.sh. Run: ./build.sh --install"
            exit 1
        fi
    fi

    # Verify image now exists
    if ! $PODMAN image exists "$FORGE_IMAGE" 2>/dev/null; then
        _error "Image still not available after build."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Ensure secrets directories exist
# ---------------------------------------------------------------------------
mkdir -p "$GH_DIR" "$GIT_DIR"
[[ -f "$GITCONFIG" ]] || touch "$GITCONFIG"

# ---------------------------------------------------------------------------
# Check for existing credentials
# ---------------------------------------------------------------------------
if [[ -f "$GH_HOSTS" ]] && [[ -s "$GH_HOSTS" ]]; then
    _warn "GitHub credentials already exist."
    show_status
    read -rp "Re-authenticate? [y/N] " answer
    case "${answer:-n}" in
        [Yy])
            _info "Proceeding with re-authentication..."
            ;;
        *)
            _info "Keeping existing credentials."
            exit 0
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Run auth flow in forge container
# ---------------------------------------------------------------------------
echo ""
echo "=== GitHub Login ==="
echo ""

# Prompt for git identity on the host side (simpler TTY handling)
read -rp "Your name (for git commits): " GIT_NAME
read -rp "Your email (for git commits): " GIT_EMAIL

if [[ -z "$GIT_NAME" ]] || [[ -z "$GIT_EMAIL" ]]; then
    _error "Name and email are required."
    exit 1
fi

# Write git identity on the host side (no container needed, avoids TTY issues)
mkdir -p "$GIT_DIR"
git config --file "$GIT_DIR/.gitconfig" user.name "$GIT_NAME"
git config --file "$GIT_DIR/.gitconfig" user.email "$GIT_EMAIL"
_info "Git identity saved"

echo ""
_info "Starting GitHub authentication..."
_info "(You'll be prompted to paste a GitHub token)"
echo ""

# Run gh auth login as the direct entrypoint — NOT via bash -c "..."
# Using bash -c breaks TTY passthrough and gh auth login hangs.
# --entrypoint "" clears the image default, then the command IS the entrypoint.
$PODMAN run -it --rm --init \
    --name tillandsias-gh-login \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --userns=keep-id \
    --security-opt=label=disable \
    --entrypoint "" \
    -e GIT_CONFIG_GLOBAL=/home/forge/.config/tillandsias-git/.gitconfig \
    -v "${GH_DIR}:/home/forge/.config/gh" \
    -v "${GIT_DIR}:/home/forge/.config/tillandsias-git:rw" \
    "$FORGE_IMAGE" \
    gh auth login --git-protocol https

# Run setup-git in a separate non-interactive container
$PODMAN run --rm --init \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --userns=keep-id \
    --security-opt=label=disable \
    --entrypoint "" \
    -e GIT_CONFIG_GLOBAL=/home/forge/.config/tillandsias-git/.gitconfig \
    -v "${GH_DIR}:/home/forge/.config/gh" \
    -v "${GIT_DIR}:/home/forge/.config/tillandsias-git" \
    "$FORGE_IMAGE" \
    gh auth setup-git 2>/dev/null || true

echo ""
_info "Authentication complete."
show_status
echo ""
read -rp "Press Enter to close..." _
