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
source "$SCRIPT_DIR/common.sh"
require_podman

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

# Deploy registries.conf — but only when it would actually CHANGE something.
#
# This script runs on every ./build.sh, and it used to back up the target
# unconditionally before an unconditional copy. With the deployed file already
# byte-identical to the source, that produced one 1397-byte backup per build
# forever: macuahuitl had accumulated 989 identical
# registries.conf.backup.<epoch> files (3.9 MB) in ~/.config/containers by
# 2026-07-29. A backup that is identical to both the source and the target
# records nothing, and an unbounded retention policy is not a policy.
#
# So: no-op when already current, and keep exactly ONE rollback copy (.prev)
# when a real change is being made.
if [[ -f "$TARGET_FILE" ]] && cmp -s "$SOURCE_FILE" "$TARGET_FILE"; then
    echo "[podman-registries] already current — no change (no backup written)"
else
    if [[ -f "$TARGET_FILE" ]]; then
        echo "[podman-registries] content differs — saving one rollback copy to $TARGET_FILE.prev"
        cp "$TARGET_FILE" "$TARGET_FILE.prev"
    fi
    cp "$SOURCE_FILE" "$TARGET_FILE"
    chmod 644 "$TARGET_FILE"
    echo "[podman-registries] ✓ Deployed registries.conf to $TARGET_FILE"
fi

# Retire the unbounded backup set left by the pre-2026-07-29 behaviour. Only
# copies that are byte-identical to what is now deployed are removed, so a
# genuinely divergent old backup is never destroyed — it is reported instead.
_pruned=0
_kept=0
for _old in "$TARGET_FILE".backup.*; do
    [[ -e "$_old" ]] || continue
    if cmp -s "$_old" "$TARGET_FILE"; then
        rm -f "$_old" && _pruned=$((_pruned + 1))
    else
        _kept=$((_kept + 1))
    fi
done
if (( _pruned > 0 || _kept > 0 )); then
    echo "[podman-registries] legacy backups: pruned $_pruned identical, kept $_kept divergent"
fi

# Verify podman recognizes it
echo "[podman-registries] Verifying podman configuration..."
SHORT_NAME_MODE=$(podman info --format '{{.RegistriesConf.ShortNameMode}}' 2>/dev/null || echo "unknown")
echo "[podman-registries] short-name-mode: $SHORT_NAME_MODE"

echo "[podman-registries] ✓ Setup complete"
