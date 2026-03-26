#!/usr/bin/env bash
set -euo pipefail

# ensure-builder.sh — Ensure the tillandsias-builder toolbox exists with Nix installed.
#
# This creates a dedicated toolbox for building container images with Nix.
# The builder toolbox is separate from any dev toolbox.

TOOLBOX_NAME="tillandsias-builder"

echo "=== Ensuring builder toolbox: ${TOOLBOX_NAME} ==="

# Step 1: Check if toolbox exists, create if not
if toolbox list --containers 2>/dev/null | grep -q "${TOOLBOX_NAME}"; then
    echo "Toolbox '${TOOLBOX_NAME}' already exists."
else
    echo "Creating toolbox '${TOOLBOX_NAME}'..."
    toolbox create --assumeyes "${TOOLBOX_NAME}"
    echo "Toolbox '${TOOLBOX_NAME}' created."
fi

# Step 2: Install Nix inside the toolbox (single-user mode with flakes)
echo "Ensuring Nix is installed inside '${TOOLBOX_NAME}'..."
toolbox run -c "${TOOLBOX_NAME}" bash -c '
    if command -v nix &>/dev/null; then
        echo "Nix is already installed."
    else
        echo "Installing Nix (single-user mode)..."
        curl -L https://nixos.org/nix/install | sh -s -- --no-daemon

        # Enable flakes
        mkdir -p ~/.config/nix
        echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
        echo "Nix installed with flakes enabled."
    fi
'

# Step 3: Verify Nix works
echo ""
echo "Verifying Nix installation..."
NIX_VERSION=$(toolbox run -c "${TOOLBOX_NAME}" bash -lc "nix --version")
echo "OK: ${NIX_VERSION}"
