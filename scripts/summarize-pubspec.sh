#!/bin/bash
# @trace spec:project-summarizers

set -euo pipefail

PUBSPEC_YAML="${1:-.}/pubspec.yaml"

# If pubspec.yaml not found, exit with code 2 (skip, not error)
if [ ! -f "$PUBSPEC_YAML" ]; then
  exit 2
fi

# Parse pubspec.yaml to extract Flutter/Dart SDK pins and dependencies

echo "### Languages"
echo ""
echo "- Dart (Flutter runtime)"
echo ""

echo "### Runtimes"
echo ""

# Extract Flutter SDK constraint (if present)
if grep -q 'flutter:' "$PUBSPEC_YAML"; then
  FLUTTER_VER=$(grep -A 2 'flutter:' "$PUBSPEC_YAML" | grep 'sdk:' | awk -F'"' '{print $2}' || echo "2.10+")
  echo "- Flutter ($FLUTTER_VER)"
fi

# Extract Dart SDK constraint
DART_VER=$(grep '^environment:' -A 3 "$PUBSPEC_YAML" | grep 'sdk:' | awk -F'"' '{print $2}' || echo "2.18+")
echo "- Dart SDK ($DART_VER)"

echo ""

echo "### Frameworks/Build Tools"
echo ""

# Check for common Flutter dependencies
if grep -q 'flame:' "$PUBSPEC_YAML"; then
  echo "- Flame (2D game engine)"
fi
if grep -q 'provider:' "$PUBSPEC_YAML"; then
  echo "- Provider (state management)"
fi
if grep -q 'riverpod:' "$PUBSPEC_YAML"; then
  echo "- Riverpod (reactive state)"
fi
if grep -q 'sqflite:' "$PUBSPEC_YAML"; then
  echo "- sqflite (SQLite database)"
fi

# Count declared dependencies
DEP_COUNT=$(grep -c '^  [a-z_]' "$PUBSPEC_YAML" || echo "0")
echo "- Pub package dependencies ($DEP_COUNT total)"
echo ""

exit 0
