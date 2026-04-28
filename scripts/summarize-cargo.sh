#!/bin/bash
# @trace spec:project-summarizers

set -euo pipefail

CARGO_TOML="${1:-.}/Cargo.toml"

# If Cargo.toml not found, exit with code 2 (skip, not error)
if [ ! -f "$CARGO_TOML" ]; then
  exit 2
fi

# Parse Cargo.toml to extract workspace metadata, dependencies, etc.

# Extract Rust version (if specified in [workspace.package])
RUST_VERSION=$(grep -m1 'rust-version' "$CARGO_TOML" | awk -F'"' '{print $2}' || echo "1.70+")

# Extract workspace name + version
WS_NAME=$(grep -m1 '^name' "$CARGO_TOML" | awk -F'"' '{print $2}' || echo "workspace")
WS_VERSION=$(grep -m1 '^version' "$CARGO_TOML" | awk -F'"' '{print $2}' || echo "0.1.0")

# Extract a few key dependencies (top 5 by looking at Cargo.toml)
DEPS=$(grep -A 100 '^\[dependencies\]' "$CARGO_TOML" | grep -v '^\[' | grep '=' | head -5 | awk -F'=' '{print $1}' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '\n' ', ' | sed 's/,$//')

# Render output under H3 headers
echo "### Languages"
echo ""
echo "- Rust ($RUST_VERSION)"
echo ""

echo "### Runtimes"
echo ""
echo "- Cargo (Rust package manager)"
echo ""

echo "### Frameworks/Build Tools"
echo ""
if grep -q 'tauri' "$CARGO_TOML"; then
  echo "- Tauri (cross-platform GUI)"
fi
if grep -q 'tokio' "$CARGO_TOML"; then
  echo "- tokio (async runtime)"
fi
if grep -q 'serde' "$CARGO_TOML"; then
  echo "- serde (serialization)"
fi
if [ -n "$DEPS" ]; then
  echo "- Key dependencies: $DEPS"
fi
echo ""

exit 0
