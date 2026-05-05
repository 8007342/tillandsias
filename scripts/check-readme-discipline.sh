#!/bin/bash
# @trace spec:project-bootstrap-readme

set -euo pipefail

README_PATH="${1:-.}/README.md"

# Counters
ERRORS=0
WARNINGS=0

# Check 1: File exists
if [ ! -f "$README_PATH" ]; then
  echo "ERROR: README.md not found at $README_PATH"
  ERRORS=$((ERRORS+1))
  exit 1
fi

# Check 2: FOR HUMANS header present
if ! grep -q '^# FOR HUMANS$' "$README_PATH"; then
  echo "ERROR: Missing '# FOR HUMANS' header"
  ERRORS=$((ERRORS+1))
fi

# Check 3: FOR ROBOTS header present
if ! grep -q '^# FOR ROBOTS$' "$README_PATH"; then
  echo "ERROR: Missing '# FOR ROBOTS' header"
  ERRORS=$((ERRORS+1))
fi

# Check 4: Auto-regen warning present
if ! grep -q 'This file is auto-regenerated on every git push' "$README_PATH"; then
  echo "ERROR: Missing auto-regeneration warning"
  ERRORS=$((ERRORS+1))
fi

# Check 5: Timestamp present and valid
if grep -q 'Generated:' "$README_PATH"; then
  TIMESTAMP=$(grep 'Generated:' "$README_PATH" | head -1 | awk -F'Generated: ' '{print $2}' | awk '{print $1}')
  if [[ ! "$TIMESTAMP" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
    echo "ERROR: Timestamp does not parse as ISO8601: $TIMESTAMP"
    ERRORS=$((ERRORS+1))
  else
    # Check if timestamp is older than 7 days
    TIMESTAMP_EPOCH=$(date -d "$TIMESTAMP" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    AGE_SECONDS=$((NOW_EPOCH - TIMESTAMP_EPOCH))
    DAYS_OLD=$((AGE_SECONDS / 86400))

    if [ $DAYS_OLD -gt 7 ]; then
      echo "WARN: README timestamp older than 7 days (age: $DAYS_OLD days)"
      WARNINGS=$((WARNINGS+1))
    fi
  fi
else
  echo "ERROR: No timestamp line found"
  ERRORS=$((ERRORS+1))
fi

# Check 6: Seven H2 sections under FOR ROBOTS
H2_SECTIONS=$(grep -c '^## ' "$README_PATH" || echo 0)

# Check for specific H2 sections
for section in "Tech Stack" "Build/Runtime Dependencies" "Security" "Architecture" "Privacy" "Recent Changes"; do
  if ! grep -q "^## $section" "$README_PATH"; then
    echo "ERROR: Missing '## $section' section"
    ERRORS=$((ERRORS+1))
  fi
done

# Check 7: requires_cheatsheets YAML block present and well-formed
if grep -q '^requires_cheatsheets:' "$README_PATH"; then
  # Simple check: verify it has a list with 'path:' and 'tier:' entries
  if ! grep -q 'path:' "$README_PATH"; then
    echo "ERROR: requires_cheatsheets block missing 'path' entries"
    ERRORS=$((ERRORS+1))
  fi
  if ! grep -q 'tier:' "$README_PATH"; then
    echo "ERROR: requires_cheatsheets block missing 'tier' entries"
    ERRORS=$((ERRORS+1))
  fi
else
  echo "ERROR: Missing 'requires_cheatsheets:' YAML block"
  ERRORS=$((ERRORS+1))
fi

# Summary
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
  echo "OK: README discipline validated"
  exit 0
elif [ $ERRORS -eq 0 ] && [ $WARNINGS -gt 0 ]; then
  echo "OK: README validated ($WARNINGS warning(s))"
  exit 0
else
  echo "FAILED: $ERRORS error(s), $WARNINGS warning(s)"
  exit 1
fi
