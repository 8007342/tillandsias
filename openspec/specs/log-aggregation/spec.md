# log-aggregation Specification

@trace spec:log-aggregation

## Status

active

## Requirements

### Requirement: Runtime logs aggregate without dropping source metadata

The logging aggregator MUST preserve source component, timestamp, severity, trace context, and spec trace metadata when collecting events from multiple producers.

#### Scenario: Aggregated event keeps provenance

- **WHEN** an event is collected from a component stream
- **THEN** the aggregated record MUST retain its original component identity
- **AND** query output MUST be able to distinguish that source from other producers

## Sources of Truth

- `cheatsheets/runtime/runtime-logging.md` - Runtime log structure
- `cheatsheets/runtime/event-driven-monitoring.md` - Event ingestion patterns

