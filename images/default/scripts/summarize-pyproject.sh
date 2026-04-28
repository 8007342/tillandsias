#!/bin/bash
# @trace spec:project-summarizers

set -euo pipefail

PYPROJECT="${1:-.}/pyproject.toml"

# If pyproject.toml not found, exit with code 2 (skip, not error)
if [ ! -f "$PYPROJECT" ]; then
  exit 2
fi

# Parse pyproject.toml to extract Python version, build-backend, and dependencies

echo "### Languages"
echo ""
echo "- Python (interpreted, dynamic typing)"
echo ""

echo "### Runtimes"
echo ""

# Extract Python version constraint (if present)
if grep -q 'requires-python' "$PYPROJECT"; then
  PYTHON_VER=$(grep 'requires-python' "$PYPROJECT" | awk -F'"' '{print $2}' || echo "3.9+")
  echo "- Python ($PYTHON_VER)"
else
  echo "- Python (3.9+)"
fi

echo ""

echo "### Frameworks/Build Tools"
echo ""

# Extract build-backend
if grep -q 'build-backend' "$PYPROJECT"; then
  BACKEND=$(grep 'build-backend' "$PYPROJECT" | awk -F'"' '{print $2}')
  echo "- Build backend: $BACKEND"
fi

# Check for Poetry (tool.poetry section)
if grep -q '\[tool.poetry\]' "$PYPROJECT"; then
  echo "- Poetry (dependency management)"
fi

# Check for pytest, pytest-cov
if grep -q 'pytest' "$PYPROJECT"; then
  echo "- pytest (testing framework)"
fi

# Count dependencies
if grep -q '\[project\]' "$PYPROJECT"; then
  DEP_COUNT=$(grep -c '^[[:space:]]*"' "$PYPROJECT" || echo "0")
elif grep -q '\[tool.poetry.dependencies\]' "$PYPROJECT"; then
  DEP_COUNT=$(grep -A 20 '\[tool.poetry.dependencies\]' "$PYPROJECT" | grep -c '^[[:space:]]*[a-z_]' || echo "0")
fi

echo "- Dependencies configured"
echo ""

exit 0
