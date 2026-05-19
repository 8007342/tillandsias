# distributed-tracing Specification

@trace spec:distributed-tracing

## Status

active

## Requirements

### Requirement: Runtime events can share trace context

Logging components that propagate span or trace context MUST preserve identifiers across event boundaries so related runtime events can be correlated after collection.

#### Scenario: Child span keeps parent context

- **WHEN** a component creates a child span from an incoming context
- **THEN** the child event MUST retain the parent trace identifier
- **AND** the relationship MUST be serializable in the logging model

## Sources of Truth

- `cheatsheets/runtime/runtime-logging.md` - Runtime logging model
- `cheatsheets/runtime/event-driven-monitoring.md` - Event correlation patterns

