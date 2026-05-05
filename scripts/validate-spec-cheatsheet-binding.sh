#!/usr/bin/env bash
# validate-spec-cheatsheet-binding.sh — audit spec-to-cheatsheet binding completeness.
#
# Purpose: Verify that every spec references at least one existing cheatsheet
# in its "## Sources of Truth" section.
#
# Usage:
#   scripts/validate-spec-cheatsheet-binding.sh [--threshold N]
#
# Exits:
#   0 — binding is >=90% (or custom --threshold)
#   1 — binding is <90%, or unresolved references exist
#   2 — fatal error
#
# OpenSpec change: cheatsheet-binding-validation
# @trace spec:cheatsheet-tooling

set -euo pipefail

THRESHOLD=90

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold) THRESHOLD="${2:-90}"; shift 2 ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
done

# Get repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SPECS_DIR="${REPO_ROOT}/openspec/specs"
CHEATSHEETS_DIR="${REPO_ROOT}/cheatsheets"

[[ -d "${SPECS_DIR}" ]] || { echo "error: specs dir not found" >&2; exit 2; }
[[ -d "${CHEATSHEETS_DIR}" ]] || { echo "error: cheatsheets dir not found" >&2; exit 2; }

cd "${REPO_ROOT}"

# Main counters
TOTAL_SPECS=0
SPECS_WITH_SECTION=0
SPECS_WITH_VALID_REFS=0
EMPTY_SOURCES=()
INVALID_ONLY=()

echo "Auditing spec-to-cheatsheet binding..." >&2

for spec_file in "${SPECS_DIR}"/*/spec.md; do
    [[ ! -f "$spec_file" ]] && continue
    spec_name="$(basename "$(dirname "$spec_file")")"
    ((++TOTAL_SPECS))

    # Skip if no "## Sources of Truth" section
    if ! grep -q "^## Sources of Truth" "$spec_file" 2>/dev/null; then
        continue
    fi

    ((++SPECS_WITH_SECTION))

    # Extract sources section
    sources=$(sed -n '/^## Sources of Truth/,/^## /p' "$spec_file" | head -n -1)

    # Count valid cheatsheet refs
    valid_count=0
    total_count=0

    while IFS= read -r ref; do
        [[ -z "$ref" ]] && continue
        ref="${ref//\`/}"
        ref="${ref#"${ref%%[![:space:]]*}"}"
        ref="${ref%"${ref##*[![:space:]]}"}"
        [[ -z "$ref" ]] && continue

        ((++total_count))
        [[ -f "$ref" ]] && ((++valid_count))
    done < <(echo "$sources" | grep -o '`[^`]*\.md`' | sed 's/`//g')

    if [[ $valid_count -eq 0 && $total_count -eq 0 ]]; then
        EMPTY_SOURCES+=("$spec_name")
    elif [[ $valid_count -eq 0 && $total_count -gt 0 ]]; then
        INVALID_ONLY+=("$spec_name")
    elif [[ $valid_count -gt 0 ]]; then
        ((++SPECS_WITH_VALID_REFS))
    fi
done

COVERAGE=$((SPECS_WITH_VALID_REFS * 100 / SPECS_WITH_SECTION))

cat << EOF

CHEATSHEET BINDING AUDIT REPORT
================================

Coverage Metrics:
  Total specs:                      $TOTAL_SPECS
  Specs with "Sources of Truth":    $SPECS_WITH_SECTION
  Specs with valid citations:       $SPECS_WITH_VALID_REFS
  Specs with empty section:         ${#EMPTY_SOURCES[@]}
  Specs with invalid-only refs:     ${#INVALID_ONLY[@]}

Coverage: ${COVERAGE}% (threshold: ${THRESHOLD}%)
Status: $([ $COVERAGE -ge $THRESHOLD ] && echo "PASS" || echo "FAIL")

EOF

if [[ ${#EMPTY_SOURCES[@]} -gt 0 ]]; then
    {
        echo "Specs with empty \"## Sources of Truth\" (${#EMPTY_SOURCES[@]}):"
        for spec in "${EMPTY_SOURCES[@]}"; do
            echo "  - $spec"
        done
        echo ""
    } >&2
fi

if [[ ${#INVALID_ONLY[@]} -gt 0 ]]; then
    {
        echo "Specs with only invalid refs (${#INVALID_ONLY[@]}):"
        for spec in "${INVALID_ONLY[@]}"; do
            echo "  - $spec"
        done
        echo ""
    } >&2
fi

[[ $COVERAGE -lt $THRESHOLD ]] && { echo "FAILED: Coverage ${COVERAGE}% < threshold ${THRESHOLD}%" >&2; exit 1; }
[[ ${#INVALID_ONLY[@]} -gt 0 ]] && { echo "FAILED: ${#INVALID_ONLY[@]} specs have unresolved refs" >&2; exit 1; }

echo "OK: Cheatsheet binding complete (${COVERAGE}%)"
exit 0
