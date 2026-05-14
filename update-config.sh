#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${CODEX_CONFIG_PATH:-$HOME/.codex/config.toml}"
PROJECT_PATH="${CODEX_PROJECT_PATH:-/var/home/machiyotl/src/tillandsias}"
PROFILE_NAME="${CODEX_PROFILE_NAME:-tillandsias}"

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "config file not found: $CONFIG_PATH" >&2
  exit 1
fi

if grep -q "^\[projects\.\"${PROJECT_PATH//\"/\\\"}\"\]" "$CONFIG_PATH" 2>/dev/null; then
  echo "project entry already exists in $CONFIG_PATH" >&2
  exit 0
fi

cat <<EOF >>"$CONFIG_PATH"

[projects."$PROJECT_PATH"]
profile = "$PROFILE_NAME"
trust_level = "trusted"

EOF

echo "appended project default profile to $CONFIG_PATH" >&2
