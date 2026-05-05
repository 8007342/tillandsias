#!/bin/bash
# @trace spec:project-summarizers

set -euo pipefail

FLAKE_NIX="${1:-.}/flake.nix"

# If flake.nix not found, exit with code 2 (skip, not error)
if [ ! -f "$FLAKE_NIX" ]; then
  exit 2
fi

# Parse flake.nix to extract system, inputs, and outputs

echo "### Languages"
echo ""
echo "- Nix (reproducible builds + environments)"
echo ""

echo "### Runtimes"
echo ""

# Extract inputs (check for common ones)
if grep -q 'nixpkgs' "$FLAKE_NIX"; then
  echo "- nixpkgs (package repository)"
fi
if grep -q 'flake-utils' "$FLAKE_NIX"; then
  echo "- flake-utils (multi-platform helpers)"
fi
if grep -q 'rust-overlay' "$FLAKE_NIX"; then
  echo "- rust-overlay (Rust toolchain)"
fi
if grep -q 'flutter' "$FLAKE_NIX"; then
  echo "- flutter (cross-platform UI)"
fi

echo ""

echo "### Frameworks/Build Tools"
echo ""

# Look for devShells or buildInputs
if grep -q 'devShell' "$FLAKE_NIX"; then
  echo "- Development shell (nix flake show)"
fi
if grep -q 'buildInputs' "$FLAKE_NIX"; then
  echo "- Custom build dependencies"
fi

echo ""

exit 0
