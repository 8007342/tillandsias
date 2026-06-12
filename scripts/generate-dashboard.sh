#!/usr/bin/env bash
set -euo pipefail

METRICS_FILE="$1"
DASHBOARD_FILE="$2"

if [[ ! -f "$METRICS_FILE" ]]; then
    exit 0
fi

# Extract times and sizes for the 'forge' image
DURATIONS=$(jq -r 'select(.image == "forge") | .duration_s' "$METRICS_FILE" | tail -n 20)
SIZES=$(jq -r 'select(.image == "forge") | .size_bytes' "$METRICS_FILE" | tail -n 20)

# Build Mermaid graph data for Duration
MERMAID_DURATION="xychart-beta
    title \"Forge Build Duration (seconds)\"
    x-axis \"Builds\" 1 -> $(echo "$DURATIONS" | wc -l | tr -d ' ')
    y-axis \"Seconds\"
    line [$(echo "$DURATIONS" | paste -sd, -)]"

# Build Mermaid graph data for Size
# Convert bytes to MB
SIZES_MB=$(echo "$SIZES" | awk '{print int($1/1024/1024)}')
MERMAID_SIZE="xychart-beta
    title \"Forge Image Size (MB)\"
    x-axis \"Builds\" 1 -> $(echo "$SIZES_MB" | wc -l | tr -d ' ')
    y-axis \"MB\"
    bar [$(echo "$SIZES_MB" | paste -sd, -)]"

cat > "$DASHBOARD_FILE" <<EOF
# Forge Build Telemetry Dashboard

Auto-generated metrics tracking the build performance and size of the forge image.

## Build Duration Over Time

\`\`\`mermaid
$MERMAID_DURATION
\`\`\`

## Image Size Over Time

\`\`\`mermaid
$MERMAID_SIZE
\`\`\`

*Metrics are extracted from \`$METRICS_FILE\` via semantic distillation.*
EOF
