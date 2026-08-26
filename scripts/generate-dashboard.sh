#!/usr/bin/env bash
set -euo pipefail


# ORDER 799-tb7q — resolve `jq` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has it.
# shellcheck source=scripts/lib/tool-dispatch.sh
# Resolve the lib by WALKING UP, not by a fixed depth (order 914-ahsy). The
# fixed form `dirname "${BASH_SOURCE[0]}"/lib/...` is correct only for a caller
# sitting directly in scripts/. From scripts/refusal-calibration/ it points at a
# lib that does not exist, the `|| true` swallows the miss, and the tool variable
# silently falls back to the bare name — a conversion that passes review, passes
# the suite, and changes nothing.
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
if command -v resolve_tool >/dev/null 2>&1; then
    JQ="$(resolve_tool jq || printf 'jq')"
else
    JQ="jq"   # lib unavailable: preserve the previous behaviour exactly
fi

METRICS_FILE="$1"
DASHBOARD_FILE="$2"

if [[ ! -f "$METRICS_FILE" ]]; then
    exit 0
fi

# Extract times and sizes for the 'forge' image
DURATIONS=$("$JQ" -r 'select(.image == "forge") | .duration_s' "$METRICS_FILE" | tail -n 20)
SIZES=$("$JQ" -r 'select(.image == "forge") | .size_bytes' "$METRICS_FILE" | tail -n 20)
BYTES_DL=$("$JQ" -r 'select(.image == "forge") | .bytes_downloaded // 0' "$METRICS_FILE" | tail -n 20)
CACHE_HITS=$("$JQ" -r 'select(.image == "forge") | .cache_hits // 0' "$METRICS_FILE" | tail -n 20)

# 766-7zqf: the dashboard is a COMMITTED, cross-host artifact, but this
# telemetry file is per-host ephemeral cache — on a host that never built the
# forge image (or a fresh worktree/checkout) the forge-filtered series is
# EMPTY, and regenerating would silently destroy the committed history (bit
# two checkouts on 2026-08-16, caught only by the boundary guard). Refuse,
# loudly, to replace a richer dashboard with a poorer one; a host with equal
# or more local data points regenerates exactly as before. Never fails the
# calling build (exit 0 — the refusal is the correct outcome, not an error).
NEW_POINTS=$(echo "$DURATIONS" | grep -c '^[0-9]' || true)
OLD_POINTS=0
if [[ -f "$DASHBOARD_FILE" ]]; then
    OLD_POINTS=$(grep -oE 'x-axis "Builds" 1 -> [0-9]+' "$DASHBOARD_FILE" | head -1 | grep -oE '[0-9]+$' || true)
    OLD_POINTS="${OLD_POINTS:-0}"
fi
if [[ "$NEW_POINTS" -lt "$OLD_POINTS" ]]; then
    echo "[generate-dashboard] REFUSED: local telemetry carries $NEW_POINTS forge build point(s) but $DASHBOARD_FILE records $OLD_POINTS — regenerating would destroy committed history (766-7zqf). Keeping the richer file." >&2
    exit 0
fi

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
