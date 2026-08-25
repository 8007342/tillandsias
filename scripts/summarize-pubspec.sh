#!/bin/bash
# @trace spec:project-summarizers
# freshness: auditor=forge-forge-tillandsias-codex-20260824t004713z date=2026-08-24 verdict=updated scope=full script; exact section parsing now preserves quoted SDK constraints, counts only direct dependency keys, and detects frameworks by dependency name; pinned by test-summarize-pubspec.sh

set -euo pipefail

PUBSPEC_YAML="${1:-.}/pubspec.yaml"

# If pubspec.yaml not found, exit with code 2 (skip, not error)
if [ ! -f "$PUBSPEC_YAML" ]; then
  exit 2
fi

# Parse the small, stable subset of pubspec.yaml that this Markdown summary
# owns. YAML is indentation-sensitive: scan only direct keys under environment,
# dependencies, and dev_dependencies so nested `sdk: flutter` entries and the
# top-level `flutter:` configuration do not inflate the dependency count.
PUBSPEC_FACTS=$(awk '
function trim(value) {
  sub(/^[[:space:]]+/, "", value)
  sub(/[[:space:]]+$/, "", value)
  return value
}
function scalar_value(line, value, quote) {
  value = line
  sub(/^[^:]*:[[:space:]]*/, "", value)
  sub(/[[:space:]]+#.*$/, "", value)
  value = trim(value)
  quote = sprintf("%c", 39)
  if ((substr(value, 1, 1) == "\"" && substr(value, length(value), 1) == "\"") ||
      (substr(value, 1, 1) == quote && substr(value, length(value), 1) == quote)) {
    value = substr(value, 2, length(value) - 2)
  }
  return value
}
/^[[:alnum:]_-]+:[[:space:]]*($|#)/ {
  section = $0
  sub(/:.*/, "", section)
  if (section == "flutter") print "flutter_project\t1"
  next
}
section == "environment" && /^  sdk:[[:space:]]*/ {
  print "dart_sdk\t" scalar_value($0)
  next
}
section == "environment" && /^  flutter:[[:space:]]*/ {
  print "flutter_sdk\t" scalar_value($0)
  next
}
(section == "dependencies" || section == "dev_dependencies") &&
    /^  [[:alnum:]_-]+:[[:space:]]*/ {
  name = $0
  sub(/^  /, "", name)
  sub(/:.*/, "", name)
  print "dependency\t" name
}
' "$PUBSPEC_YAML")

DART_VER=$(printf '%s\n' "$PUBSPEC_FACTS" | awk -F '\t' '$1 == "dart_sdk" { print $2; exit }')
FLUTTER_VER=$(printf '%s\n' "$PUBSPEC_FACTS" | awk -F '\t' '$1 == "flutter_sdk" { print $2; exit }')
DEPENDENCIES=$(printf '%s\n' "$PUBSPEC_FACTS" | awk -F '\t' '$1 == "dependency" { print $2 }')
DEP_COUNT=$(printf '%s\n' "$PUBSPEC_FACTS" | awk -F '\t' '$1 == "dependency" { count++ } END { print count + 0 }')

has_dependency() {
  printf '%s\n' "$DEPENDENCIES" | grep -Fxq "$1"
}

if has_dependency flutter || printf '%s\n' "$PUBSPEC_FACTS" | grep -Fq $'flutter_project\t1'; then
  IS_FLUTTER=1
else
  IS_FLUTTER=0
fi

echo "### Languages"
echo ""
if [ "$IS_FLUTTER" -eq 1 ]; then
  echo "- Dart (Flutter project)"
else
  echo "- Dart"
fi
echo ""

echo "### Runtimes"
echo ""

# Extract the explicit Flutter constraint when present. A normal Flutter
# project often declares only `dependencies.flutter.sdk: flutter`; say that
# plainly instead of inventing a version.
if [ "$IS_FLUTTER" -eq 1 ]; then
  if [ -n "$FLUTTER_VER" ]; then
    echo "- Flutter ($FLUTTER_VER)"
  else
    echo "- Flutter (SDK dependency)"
  fi
fi

# An absent constraint is unknown, not evidence for a made-up floor.
DART_VER=${DART_VER:-unspecified}
echo "- Dart SDK ($DART_VER)"

echo ""

echo "### Frameworks/Build Tools"
echo ""

# Check exact direct dependency names. Raw substring scans used to report
# Provider for packages such as provider_tools and could match comments.
if has_dependency flame; then
  echo "- Flame (2D game engine)"
fi
if has_dependency provider; then
  echo "- Provider (state management)"
fi
if has_dependency riverpod; then
  echo "- Riverpod (reactive state)"
fi
if has_dependency sqflite; then
  echo "- sqflite (SQLite database)"
fi

echo "- Direct pub dependencies ($DEP_COUNT total)"
echo ""

exit 0
