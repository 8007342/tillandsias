#!/usr/bin/env bash
# @trace spec:cheatsheet-tooling, spec:cheatsheet-source-layer
# Check for stale cheatsheets older than 90 days.
# Usage: ./check-cheatsheet-staleness.sh [--days 90] [--check-urls]
#
# By default: flags cheatsheets whose "Last updated: YYYY-MM-DD" is > 90 days old.
# With --check-urls: also attempts to reach cited URLs (slow, requires network).

set -euo pipefail

CHEATSHEETS_DIR="${TILLANDSIAS_CHEATSHEETS:-./cheatsheets}"
STALENESS_DAYS="${1:-90}"
CHECK_URLS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) STALENESS_DAYS="$2"; shift 2 ;;
        --check-urls) CHECK_URLS=1; shift ;;
        *) shift ;;
    esac
done

if [[ ! -d "$CHEATSHEETS_DIR" ]]; then
    echo "ERROR: CHEATSHEETS_DIR not found: $CHEATSHEETS_DIR" >&2
    exit 1
fi

today_epoch=$(date +%s)
found_stale=0

echo "Checking cheatsheets for staleness (> $STALENESS_DAYS days)..."
echo ""

for cheatsheet in $(find "$CHEATSHEETS_DIR" -name "*.md" -type f ! -name "INDEX.md" ! -name "TEMPLATE.md"); do
    # Extract "Last updated: YYYY-MM-DD"
    last_updated=$(grep -E "^\*\*Last updated:\*\*" "$cheatsheet" | head -1 | sed 's/.*Last updated: //; s/\*\*.*//; s/`//g' || echo "")

    if [[ -z "$last_updated" ]]; then
        echo "MISSING_DATE: $cheatsheet (no 'Last updated:' line found)"
        found_stale=$((found_stale + 1))
        continue
    fi

    # Convert date to epoch
    last_updated_epoch=$(date -d "$last_updated" +%s 2>/dev/null || echo "")

    if [[ -z "$last_updated_epoch" ]]; then
        echo "INVALID_DATE: $cheatsheet (could not parse: $last_updated)"
        found_stale=$((found_stale + 1))
        continue
    fi

    # Calculate age in days
    age_seconds=$((today_epoch - last_updated_epoch))
    age_days=$((age_seconds / 86400))

    if [[ $age_days -gt $STALENESS_DAYS ]]; then
        echo "STALE ($age_days days): $cheatsheet (last updated: $last_updated)"
        found_stale=$((found_stale + 1))

        # Optionally check URL reachability
        if [[ $CHECK_URLS -eq 1 ]]; then
            urls=$(grep -E "^- <https?://" "$cheatsheet" | sed 's/- <//' | sed 's/> .*//' || echo "")
            for url in $urls; do
                if curl -fsSI --max-time 5 "$url" > /dev/null 2>&1; then
                    echo "  ✓ URL reachable: $url"
                else
                    echo "  ✗ URL unreachable: $url"
                fi
            done
        fi
    fi
done

echo ""
if [[ $found_stale -eq 0 ]]; then
    echo "All cheatsheets are up to date (≤ $STALENESS_DAYS days)."
    exit 0
else
    echo "Found $found_stale stale cheatsheet(s)."
    echo "Action: Re-fetch cited URLs, verify content, and bump 'Last updated:' date."
    exit 1
fi
