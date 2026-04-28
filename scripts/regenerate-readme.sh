#!/bin/bash
# @trace spec:project-bootstrap-readme

set -euo pipefail

PROJECT_ROOT="${1:-.}"

# Find project root (stop at .git/ or .tillandsias/)
while [ "$PROJECT_ROOT" != "/" ]; do
  if [ -d "$PROJECT_ROOT/.git" ] || [ -d "$PROJECT_ROOT/.tillandsias" ]; then
    break
  fi
  PROJECT_ROOT="$(dirname "$PROJECT_ROOT")"
done

if [ ! -d "$PROJECT_ROOT/.git" ]; then
  PROJECT_ROOT="$1"
fi

cd "$PROJECT_ROOT" || exit 1

# Load previous readme.traces (if present)
TRACES_FILE=".tillandsias/readme.traces"
mkdir -p .tillandsias

# Collect summarizer outputs
TECH_STACK=""
BUILD_DEPS=""

for summarizer in /opt/summarizers/*.sh scripts/.tillandsias/summarizers/*.sh; do
  if [ ! -f "$summarizer" ]; then
    continue
  fi

  output=$("$summarizer" 2>/dev/null || true)
  exit_code=$?

  if [ $exit_code -eq 0 ]; then
    TECH_STACK+="$output"$'\n'
  elif [ $exit_code -eq 2 ]; then
    # Skip silently (manifest not found)
    :
  fi
done

# Load previous README.md (extract agent-curated sections)
SECURITY=""
ARCHITECTURE=""
PRIVACY=""
RECENT_CHANGES=""
OPENSPEC=""
REQUIRES_CHEATSHEETS=""

if [ -f README.md ]; then
  # Extract sections between headers
  SECURITY=$(sed -n '/^## Security/,/^## /p' README.md | sed '$d' || true)
  ARCHITECTURE=$(sed -n '/^## Architecture/,/^## /p' README.md | sed '$d' || true)
  PRIVACY=$(sed -n '/^## Privacy/,/^## /p' README.md | sed '$d' || true)
  REQUIRES_CHEATSHEETS=$(sed -n '/^requires_cheatsheets:/,/^$/p' README.md || true)
fi

# Build FOR HUMANS section
TIMESTAMP=$(date -u -Iminutes)
PROJECT_NAME=$(basename "$PROJECT_ROOT" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')

FOR_HUMANS=$(cat <<'HUMANS_END'
# FOR HUMANS

> ⚠️ This file is auto-regenerated on every git push.
> Edit source files (Cargo.toml, package.json, flake.nix, etc.),
> then push. The README will rebuild itself.

HUMANS_END
)

FOR_HUMANS+=$'\n'"Generated: $TIMESTAMP (UTC)"$'\n\n'
FOR_HUMANS+="## 🌺 $PROJECT_NAME"$'\n\n'
FOR_HUMANS+="A Tillandsias-managed project orchestrating development environments."$'\n\n'

# Build FOR ROBOTS section
FOR_ROBOTS=$(cat <<'ROBOTS_END'
# FOR ROBOTS

## Tech Stack

ROBOTS_END
)

FOR_ROBOTS+=$'\n'"$TECH_STACK"$'\n'

FOR_ROBOTS+=$'## Build/Runtime Dependencies\n\n'"$BUILD_DEPS"$'\n'

# Add Security/Architecture/Privacy (use previous or insert TODOs)
if [ -n "$SECURITY" ]; then
  FOR_ROBOTS+="$SECURITY"$'\n\n'
else
  FOR_ROBOTS+=$'## Security\n\nTODO: Add security notes (authentication, data handling, threat model)\n\n'
fi

if [ -n "$ARCHITECTURE" ]; then
  FOR_ROBOTS+="$ARCHITECTURE"$'\n\n'
else
  FOR_ROBOTS+=$'## Architecture\n\nTODO: Add architecture notes (structure, layers, major modules)\n\n'
fi

if [ -n "$PRIVACY" ]; then
  FOR_ROBOTS+="$PRIVACY"$'\n\n'
else
  FOR_ROBOTS+=$'## Privacy\n\nTODO: Add privacy notes (data collection, storage, user consent)\n\n'
fi

# Add Recent Changes
FOR_ROBOTS+=$'## Recent Changes\n\n'
if git rev-parse HEAD >/dev/null 2>&1; then
  git log --oneline -10 2>/dev/null | while read line; do
    FOR_ROBOTS+="- $line"$'\n'
  done
fi
FOR_ROBOTS+=$'\n'

# Add OpenSpec items (if available)
if command -v openspec >/dev/null 2>&1; then
  FOR_ROBOTS+=$'## OpenSpec — Open Items\n\n'
  openspec list --oneline 2>/dev/null | head -5 | while read line; do
    FOR_ROBOTS+="- $line"$'\n'
  done || true
  FOR_ROBOTS+=$'\n'
fi

# Add requires_cheatsheets
if [ -z "$REQUIRES_CHEATSHEETS" ]; then
  REQUIRES_CHEATSHEETS=$(cat <<'YAML_END'
requires_cheatsheets:
  - path: "welcome/sample-prompts.md"
    tier: bundled
  - path: "runtime/agent-startup-skills.md"
    tier: bundled
  - path: "runtime/forge-paths-ephemeral-vs-persistent.md"
    tier: bundled
YAML_END
)
fi

FOR_ROBOTS+="$REQUIRES_CHEATSHEETS"$'\n'

# Write README.md atomically
README_CONTENT="$FOR_HUMANS"$'\n'"$FOR_ROBOTS"

echo "$README_CONTENT" > README.md.tmp
mv README.md.tmp README.md

# Append to traces
echo "{\"ts\": \"$(date -u -Iseconds)\", \"agent\": \"regenerate-readme\", \"observation\": \"README regenerated\", \"severity\": \"info\"}" >> "$TRACES_FILE"

exit 0
