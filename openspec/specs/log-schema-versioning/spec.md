# log-schema-versioning Specification

@trace spec:log-schema-versioning

## Status

active

## Requirements

### Requirement: Log entries carry schema version

Structured log entries MUST include a schema version so readers can handle additive changes and reject incompatible records deliberately.

#### Scenario: Reader sees unknown schema version

- **WHEN** a log reader encounters a future incompatible schema version
- **THEN** it MUST report the unsupported version
- **AND** it MUST NOT reinterpret the record as the current schema

## Sources of Truth

- `cheatsheets/runtime/runtime-logging.md` - Structured logging conventions
- `cheatsheets/runtime/version-file-conventions.md` - Versioning reference

