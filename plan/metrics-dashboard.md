# Forge Build Telemetry Dashboard

Auto-generated metrics tracking the build performance and size of the forge image.

## Build Duration Over Time

```mermaid
xychart-beta
    title "Forge Build Duration (seconds)"
    x-axis "Builds" 1 -> 9
    y-axis "Seconds"
    line [10,12,93,105,65,20,28,20,143]
```

## Image Size Over Time

```mermaid
xychart-beta
    title "Forge Image Size (MB)"
    x-axis "Builds" 1 -> 9
    y-axis "MB"
    bar [6053,2960,2960,2955,2957,2973,2985,2985,2985]
```

## Download Size Over Time

```mermaid
xychart-beta
    title "Forge Build Download Size (MB)"
    x-axis "Builds" 1 -> 9
    y-axis "MB"
    bar [0,0,0,0,0,0,0,0,0]
```

## Latest Build Summary

| Metric | Value |
|---|---|
| Duration | 143s |
| Image Size | 2985 MB |
| Bytes Downloaded | 0 MB |
| Cache Hits (steps) | 0 |

*Metrics are extracted from the build metrics input via semantic distillation. \
New in this version: download-size tracking, cache-hit tracking, and canonical ImageBuildEvent sink (`$XDG_STATE_HOME/tillandsias/image-build-events.jsonl`).*
