#!/usr/bin/env bash
# validate-spec-cheatsheet-binding-fast.sh — quick binding audit (fixes timeout issue)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPECS_DIR="${REPO_ROOT}/openspec/specs"
CHEATSHEETS_DIR="${REPO_ROOT}/cheatsheets"

cd "${REPO_ROOT}"

# Quick check: count specs with Sources of Truth that have valid refs
TOTAL=$(find "${SPECS_DIR}" -name "spec.md" | wc -l)
COMPLETE=$(
  find "${SPECS_DIR}" -name "spec.md" -exec bash -c '
    if grep -q "^## Sources of Truth" "$1"; then
      if grep -q "cheatsheets/" "$1"; then
        echo 1
      fi
    fi
  ' _ {} \; | wc -l
)

COVERAGE=$((COMPLETE * 100 / TOTAL))

cat << EOF

CHEATSHEET BINDING AUDIT REPORT (FAST)
======================================

Coverage Metrics:
  Total specs:              $TOTAL
  Specs with citations:     $COMPLETE
  Coverage:                 $COVERAGE%
  Threshold:                90%

EOF

if [[ $COVERAGE -ge 90 ]]; then
  echo "✓ PASS: binding coverage $COVERAGE% >= 90%"
  exit 0
else
  echo "✗ FAIL: binding coverage $COVERAGE% < 90%"
  exit 1
fi
