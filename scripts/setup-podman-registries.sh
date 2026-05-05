#!/usr/bin/env bash
# Setup podman registries configuration for Tillandsias
# @trace spec:podman-registries-config
#
# Ensures registries.conf is deployed to ~/.config/containers/ to:
# - Disable short-name resolution TTY prompts
# - Enforce bare names for local images (tillandsias-git:v0.1.x)
# - Require fully-qualified names for external images (docker.io/...)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers"
SOURCE_FILE="$ROOT/.config/containers/registries.conf"
TARGET_FILE="$CONFIG_DIR/registries.conf"

echo "[podman-registries] Setting up podman registries configuration..."

# Verify source file exists
if [[ ! -f "$SOURCE_FILE" ]]; then
    echo "ERROR: Source registries.conf not found at $SOURCE_FILE"
    exit 1
fi

# Create config directory if needed
mkdir -p "$CONFIG_DIR"

# Backup existing registries.conf if present
if [[ -f "$TARGET_FILE" ]]; then
    BACKUP="$TARGET_FILE.backup.$(date +%s)"
    echo "[podman-registries] Backing up existing registries.conf to $BACKUP"
    cp "$TARGET_FILE" "$BACKUP"
fi

# Deploy registries.conf
cp "$SOURCE_FILE" "$TARGET_FILE"
chmod 644 "$TARGET_FILE"

echo "[podman-registries] ✓ Deployed registries.conf to $TARGET_FILE"

# Verify podman recognizes it
if command -v podman &>/dev/null; then
    echo "[podman-registries] Verifying podman configuration..."
    SHORT_NAME_MODE=$(podman info --format '{{.RegistriesConf.ShortNameMode}}' 2>/dev/null || echo "unknown")
    echo "[podman-registries] short-name-mode: $SHORT_NAME_MODE"
else
    echo "[podman-registries] WARN: podman not found, skipping verification"
fi

echo "[podman-registries] ✓ Setup complete"
