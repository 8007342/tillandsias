#!/bin/bash
# @trace spec:project-summarizers

set -euo pipefail

PKG_JSON="${1:-.}/package.json"

# If package.json not found, exit with code 2 (skip, not error)
if [ ! -f "$PKG_JSON" ]; then
  exit 2
fi

# Parse package.json to extract Node version, npm/yarn, and key dependencies

echo "### Languages"
echo ""
echo "- JavaScript / TypeScript (Node.js)"
echo ""

echo "### Runtimes"
echo ""

# Check for Node version constraint
if grep -q '"node"' "$PKG_JSON"; then
  NODE_VER=$(grep -m1 '"node"' "$PKG_JSON" | awk -F'"' '{print $4}')
  echo "- Node.js ($NODE_VER)"
else
  echo "- Node.js (14.0+)"
fi

# Detect package manager
if [ -f "pnpm-lock.yaml" ]; then
  echo "- pnpm (package manager)"
elif [ -f "yarn.lock" ]; then
  echo "- yarn (package manager)"
else
  echo "- npm (package manager)"
fi

echo ""

echo "### Frameworks/Build Tools"
echo ""

# Check for common frameworks/tools
if grep -q 'next' "$PKG_JSON"; then
  echo "- Next.js (React framework)"
fi
if grep -q 'react' "$PKG_JSON"; then
  echo "- React (UI library)"
fi
if grep -q 'typescript' "$PKG_JSON"; then
  echo "- TypeScript (type-safe JS)"
fi
if grep -q 'webpack' "$PKG_JSON"; then
  echo "- Webpack (bundler)"
fi
if grep -q 'vite' "$PKG_JSON"; then
  echo "- Vite (build tool)"
fi

# Count dependencies
DEP_COUNT=$(grep -c '"' "$PKG_JSON" || echo "0")
echo "- Dependencies configured ($DEP_COUNT total)"
echo ""

exit 0
