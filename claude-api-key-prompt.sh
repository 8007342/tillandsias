#!/usr/bin/env bash
# =============================================================================
# claude-api-key-prompt.sh — Anthropic API key entry for Tillandsias
#
# Prompts the user to paste their Anthropic API key and writes it to a
# temp file that the tray app reads and stores in the OS keyring.
#
# The temp file is created with mode 0600 and lives under XDG_RUNTIME_DIR
# (RAM-backed on Linux) so it never hits disk.
# =============================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# Platform-aware temp directory: $XDG_RUNTIME_DIR on Linux, $TMPDIR on macOS
if [[ "$(uname -s)" == "Darwin" ]]; then
    TEMP_FILE="${TMPDIR:-/tmp}/tillandsias-claude-key"
else
    TEMP_FILE="${XDG_RUNTIME_DIR:-/tmp}/tillandsias-claude-key"
fi

echo ""
echo "=== Claude Login ==="
echo ""
echo "Enter your Anthropic API key."
echo -e "Get one at: ${YELLOW}https://console.anthropic.com/settings/keys${NC}"
echo "The key starts with 'sk-ant-'"
echo ""
read -s -r -p "API Key: " key
echo ""

if [ -z "$key" ]; then
    echo -e "${RED}No key entered. Cancelled.${NC}"
    echo ""
    read -r -p "Press Enter to close..." _
    exit 0
fi

if [[ ! "$key" == sk-ant-* ]]; then
    echo -e "${YELLOW}Warning: key does not start with 'sk-ant-' — saving anyway.${NC}"
fi

# Write to temp file with restrictive permissions
umask 0177
echo -n "$key" > "$TEMP_FILE"

echo -e "${GREEN}Key saved. Tillandsias will pick it up shortly.${NC}"
echo ""
read -r -p "Press Enter to close..." _
