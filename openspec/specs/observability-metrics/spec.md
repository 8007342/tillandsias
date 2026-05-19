# observability-metrics Specification

@trace spec:observability-metrics

## Status

active

## Requirements

### Requirement: Runtime metrics expose current system health

Metrics components MUST expose process, container, and runtime health measurements in a form suitable for local dashboards and diagnostics.

#### Scenario: Metrics scrape returns structured values

- **WHEN** the metrics endpoint or sampler is queried
- **THEN** it MUST return structured measurements with stable names and units
- **AND** collection failure MUST be represented as an error or absent sample, not a fabricated healthy value

## Sources of Truth

- `cheatsheets/observability/cheatsheet-metrics.md` - Metrics conventions
- `cheatsheets/runtime/tray-performance-profiling.md` - Runtime performance measurements

