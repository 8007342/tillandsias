#!/bin/bash
# @trace gap:OBS-005, gap:OBS-025, spec:clickable-trace-index, spec:enforce-trace-presence
# Audit script to detect dead trace annotations in the codebase.
# Dead traces are @trace annotations referencing specs that no longer exist (marked as "not found" in TRACES.md).
#
# Exit codes:
#   0 - No dead traces found
#   1 - Dead traces found (can be used as CI gate)
#   2 - Script error (missing TRACES.md, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACES_FILE="$PROJECT_ROOT/TRACES.md"

# Color codes for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Track results
DEAD_TRACES_FOUND=0
TOTAL_DEAD_TRACES=0

# Helper: Print error message
error() {
    echo -e "${RED}ERROR${NC}: $*" >&2
}

# Helper: Print warning message
warn() {
    echo -e "${YELLOW}WARN${NC}: $*"
}

# Helper: Print success message
success() {
    echo -e "${GREEN}✓${NC} $*"
}

# Verify TRACES.md exists
if [[ ! -f "$TRACES_FILE" ]]; then
    error "TRACES.md not found at $TRACES_FILE"
    echo "Generate it first with: ./scripts/generate-traces.sh"
    exit 2
fi

# Extract all specs marked as "(not found)" from TRACES.md
# Format: | \`spec:name\` | (not found) | ...
echo "Analyzing TRACES.md for dead traces..."

# Use grep to find all lines with "(not found)" and extract spec names
DEAD_SPECS=$(grep -o '| `spec:[^`]*` | (not found)' "$TRACES_FILE" | sed -E 's/\| `spec:([^`]*)` \| \(not found\)/\1/' | sort -u)

if [[ -z "$DEAD_SPECS" ]]; then
    success "No dead traces found in TRACES.md"
    exit 0
fi

# For each dead spec, find all @trace annotations in the codebase
echo ""
echo "Dead specs detected: $(echo "$DEAD_SPECS" | wc -l)"
echo ""

for spec_name in $DEAD_SPECS; do
    echo "Checking for traces of dead spec: $spec_name"

    # Search for @trace annotations referencing this spec
    # Patterns: @trace spec:name or @trace spec:name,
    TRACES=$(grep -r "@trace.*spec:$spec_name" "$PROJECT_ROOT" \
        --include="*.rs" \
        --include="*.sh" \
        --include="*.md" \
        --include="*.toml" \
        --include="Containerfile*" \
        --exclude-dir=target \
        --exclude-dir=.git \
        2>/dev/null || true)

    if [[ -n "$TRACES" ]]; then
        DEAD_TRACES_FOUND=1

        # Parse and report each dead trace location
        while IFS= read -r line; do
            if [[ -z "$line" ]]; then
                continue
            fi

            # Extract file path and line number
            FILE=$(echo "$line" | cut -d: -f1)
            FILE_REL="${FILE#$PROJECT_ROOT/}"
            LINE_NUM=$(echo "$line" | cut -d: -f2)

            TOTAL_DEAD_TRACES=$((TOTAL_DEAD_TRACES + 1))

            warn "Dead trace #$TOTAL_DEAD_TRACES: @trace spec:$spec_name"
            echo "  File: $FILE_REL:$LINE_NUM"
            echo "  Action: Replace with valid spec, remove annotation, or update TRACES.md"
            echo ""
        done < <(echo "$TRACES")
    fi
done

# Summary and exit
if [[ $DEAD_TRACES_FOUND -eq 1 ]]; then
    echo ""
    error "Found $TOTAL_DEAD_TRACES dead trace(s) referencing non-existent specs"
    echo ""
    echo "To fix:"
    echo "  1. Review each file:line location above"
    echo "  2. Either:"
    echo "     a) Update @trace annotation to reference an existing spec"
    echo "     b) Remove the @trace annotation if code is obsolete"
    echo "     c) Check if spec was archived and update accordingly"
    echo "  3. Re-run: ./scripts/generate-traces.sh"
    echo "  4. Re-run: ./scripts/audit-dead-traces.sh"
    echo ""
    exit 1
else
    success "No dead traces found"
    exit 0
fi
