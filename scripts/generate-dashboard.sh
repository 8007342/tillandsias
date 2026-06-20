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
BYTES_DL=$(jq -r 'select(.image == "forge") | .bytes_downloaded // 0' "$METRICS_FILE" | tail -n 20)
CACHE_HITS=$(jq -r 'select(.image == "forge") | .cache_hits // 0' "$METRICS_FILE" | tail -n 20)

# Build Mermaid graph data for Duration
COUNT_D=$(echo "$DURATIONS" | wc -l | tr -d ' ')
MERMAID_DURATION="xychart-beta
    title \"Forge Build Duration (seconds)\"
    x-axis \"Builds\" 1 -> ${COUNT_D}
    y-axis \"Seconds\"
    line [$(echo "$DURATIONS" | paste -sd, -)]"

# Build Mermaid graph data for Size (bytes -> MB)
SIZES_MB=$(echo "$SIZES" | awk '{print int($1/1024/1024)}')
MERMAID_SIZE="xychart-beta
    title \"Forge Image Size (MB)\"
    x-axis \"Builds\" 1 -> $(echo "$SIZES_MB" | wc -l | tr -d ' ')
    y-axis \"MB\"
    bar [$(echo "$SIZES_MB" | paste -sd, -)]"

# Build Mermaid graph for bytes downloaded
COUNT_B=$(echo "$BYTES_DL" | wc -l | tr -d ' ')
BYTES_DL_MB=$(echo "$BYTES_DL" | awk '{print int($1/1024/1024)}')
MERMAID_BYTES="xychart-beta
    title \"Forge Build Download Size (MB)\"
    x-axis \"Builds\" 1 -> ${COUNT_B}
    y-axis \"MB\"
    bar [$(echo "$BYTES_DL_MB" | paste -sd, -)]"

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

## Download Size Over Time

\`\`\`mermaid
$MERMAID_BYTES
\`\`\`

## Latest Build Summary

| Metric | Value |
|---|---|
| Duration | $(echo "$DURATIONS" | tail -1)s |
| Image Size | $(echo "$SIZES_MB" | tail -1) MB |
| Bytes Downloaded | $(echo "$BYTES_DL_MB" | tail -1) MB |
| Cache Hits (steps) | $(echo "$CACHE_HITS" | tail -1) |

*Metrics are extracted from the build metrics input via semantic distillation. \\
New in this version: download-size tracking, cache-hit tracking, and canonical ImageBuildEvent sink (\`\$XDG_STATE_HOME/tillandsias/image-build-events.jsonl\`).*
EOF
