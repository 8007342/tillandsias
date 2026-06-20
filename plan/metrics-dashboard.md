# Forge Build Telemetry Dashboard

Auto-generated metrics tracking the build performance and size of the forge image.

## Build Duration Over Time

```mermaid
xychart-beta
    title "Forge Build Duration (seconds)"
    x-axis "Builds" 1 -> 1
    y-axis "Seconds"
    line []
```

## Image Size Over Time

```mermaid
xychart-beta
    title "Forge Image Size (MB)"
    x-axis "Builds" 1 -> 1
    y-axis "MB"
    bar [0]
```

## Download Size Over Time

```mermaid
xychart-beta
    title "Forge Build Download Size (MB)"
    x-axis "Builds" 1 -> 1
    y-axis "MB"
    bar [0]
```

## Latest Build Summary

| Metric | Value |
|---|---|
| Duration | s |
| Image Size | 0 MB |
| Bytes Downloaded | 0 MB |
| Cache Hits (steps) |  |

*Metrics are extracted from `/tmp/tmp.kGzJuxKcPv/home/.cache/tillandsias/telemetry/build-metrics.jsonl` via semantic distillation. \
New in this version: download-size tracking, cache-hit tracking, and canonical ImageBuildEvent sink (`$XDG_STATE_HOME/tillandsias/image-build-events.jsonl`).*
