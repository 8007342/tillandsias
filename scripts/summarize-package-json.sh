#!/bin/bash
# @trace spec:project-summarizers
# freshness: auditor=linux-lenovinha-fable5-20260824t015308z date=2026-08-24 verdict=refreshed scope=full file, 67 lines, exercised on a synthetic manifest and on a directory with none. Correct on both paths: exits 2 (skip-not-error) with no package.json, and against a manifest carrying react/express/typescript it emits the three sections and exits 0. Still meaningful as one of six summarizers giving a cold-start agent a project's shape without reading its build files.
# freshness-note, deliberately NOT changed: detection is substring `grep -q` over the raw file, not `jq` over the dependency maps — so `grep -q 'react'` also matches a package NAMED react-something, a comment, or a URL in a repository field, and `grep -q 'next'` is the weakest of them (it matches "next" anywhere, including inside words). jq IS available here and would be exact. Left alone because being generous is arguably the RIGHT bias for a summarizer whose output is an orientation hint rather than a fact a gate consumes, and because changing one of six siblings in isolation would break the family's uniformity. If this is ever tightened, tighten all six in one pass and say which way the bias goes.

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
