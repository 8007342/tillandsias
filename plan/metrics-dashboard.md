# Forge Build Telemetry Dashboard

Auto-generated metrics tracking the build performance and size of the forge image.

> Current provenance: stale/cache-empty. This file contains no live metrics input
> for 2026-07-05 and must not be used as evidence for current forge build
> performance. Order 192 owns refreshing the generator so empty input fails closed
> with a source timestamp instead of rendering zero/blank charts.

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

*Metrics are extracted from the build metrics input via semantic distillation. \
New in this version: download-size tracking, cache-hit tracking, and canonical ImageBuildEvent sink (`$XDG_STATE_HOME/tillandsias/image-build-events.jsonl`).*
