#!/bin/bash
# @trace spec:project-summarizers

set -euo pipefail

GO_MOD="${1:-.}/go.mod"

# If go.mod not found, exit with code 2 (skip, not error)
if [ ! -f "$GO_MOD" ]; then
  exit 2
fi

# Parse go.mod to extract Go version and top-level requires

echo "### Languages"
echo ""
echo "- Go (compiled, statically-linked)"
echo ""

echo "### Runtimes"
echo ""

# Extract Go version from 'go X.Y' line
GO_VERSION=$(head -5 "$GO_MOD" | grep '^go ' | awk '{print $2}' || echo "1.20+")
echo "- Go ($GO_VERSION)"

echo ""

echo "### Frameworks/Build Tools"
echo ""

# Extract a few key requires (limit to 5)
if grep -q '^require' "$GO_MOD"; then
  REQUIRES=$(grep -A 10 '^require' "$GO_MOD" | grep -v '^require' | grep -v '^)' | head -5 | awk '{print $1}' | paste -sd ',' - | sed 's/,/, /g')
  if [ -n "$REQUIRES" ]; then
    echo "- Key dependencies: $REQUIRES"
  fi
fi

# Check for go.sum for module lock file
if [ -f "go.sum" ]; then
  echo "- Module lock file (go.sum)"
fi

echo ""

exit 0
