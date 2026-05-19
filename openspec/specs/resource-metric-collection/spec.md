# resource-metric-collection Specification

@trace spec:resource-metric-collection

## Status

active

## Requirements

### Requirement: Resource samplers collect bounded measurements

Resource metric collection MUST sample CPU, memory, disk, and process/container data without blocking the runtime control path indefinitely.

#### Scenario: Sampler cannot read a resource

- **WHEN** a platform resource cannot be read
- **THEN** the sampler MUST surface a collection error or omit that sample
- **AND** other independent metrics MUST still be collected when possible

## Sources of Truth

- `cheatsheets/observability/cheatsheet-metrics.md` - Metrics definitions
- `cheatsheets/runtime/tray-performance-profiling.md` - Runtime profiling context

