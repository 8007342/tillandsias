#!/bin/bash
# @trace spec:project-summarizers
# freshness: auditor=forge-forge-tillandsias-codex-20260824t004713z date=2026-08-24 verdict=updated scope=hermetic behavior pin added with the summarize-pubspec freshness repair

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUMMARIZER="$ROOT/scripts/summarize-pubspec.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local output="$1"
  local expected="$2"
  printf '%s\n' "$output" | grep -Fq -- "$expected" \
    || fail "missing output: $expected"
}

mkdir -p "$TMP/flutter" "$TMP/dart"

printf '%s\n' \
  'name: freshness_probe' \
  'version: 1.2.3' \
  'environment:' \
  "  sdk: '>=3.4.0 <4.0.0'" \
  '  flutter: ">=3.22.0"' \
  'dependencies:' \
  '  flutter:' \
  '    sdk: flutter' \
  '  riverpod: ^2.5.1' \
  '  provider: ^6.1.2' \
  'dev_dependencies:' \
  '  flutter_test:' \
  '    sdk: flutter' \
  '  lints: ^4.0.0' \
  'flutter:' \
  '  uses-material-design: true' \
  >"$TMP/flutter/pubspec.yaml"

flutter_output=$("$SUMMARIZER" "$TMP/flutter")
assert_contains "$flutter_output" '- Dart (Flutter project)'
assert_contains "$flutter_output" '- Flutter (>=3.22.0)'
assert_contains "$flutter_output" '- Dart SDK (>=3.4.0 <4.0.0)'
assert_contains "$flutter_output" '- Provider (state management)'
assert_contains "$flutter_output" '- Riverpod (reactive state)'
assert_contains "$flutter_output" '- Direct pub dependencies (5 total)'
[ "$flutter_output" = "$("$SUMMARIZER" "$TMP/flutter")" ] \
  || fail "same manifest produced different output"

printf '%s\n' \
  'name: dart_only' \
  'environment:' \
  '  sdk: ">=3.3.0 <4.0.0"' \
  'dependencies:' \
  '  provider_tools: ^1.0.0' \
  >"$TMP/dart/pubspec.yaml"

dart_output=$("$SUMMARIZER" "$TMP/dart")
assert_contains "$dart_output" '- Dart SDK (>=3.3.0 <4.0.0)'
assert_contains "$dart_output" '- Direct pub dependencies (1 total)'
if printf '%s\n' "$dart_output" | grep -Fq 'Flutter'; then
  fail "Dart-only manifest was reported as Flutter"
fi
if printf '%s\n' "$dart_output" | grep -Fq 'Provider (state management)'; then
  fail "provider_tools was reported as provider"
fi

set +e
missing_output=$("$SUMMARIZER" "$TMP/missing" 2>&1)
missing_rc=$?
set -e
[ "$missing_rc" -eq 2 ] || fail "missing manifest returned $missing_rc, expected 2"
[ -z "$missing_output" ] || fail "missing manifest wrote output"

echo "PASS: summarize-pubspec behavior (3/3)"
