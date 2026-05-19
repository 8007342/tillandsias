# structured-query-language Specification

@trace spec:structured-query-language

## Status

active

## Requirements

### Requirement: Trace queries use structured predicates

Trace query tooling MUST support structured predicates over trace metadata instead of relying only on ad hoc text search.

#### Scenario: Query filters by spec trace

- **WHEN** a query specifies a spec trace predicate
- **THEN** results MUST include matching trace entries
- **AND** entries for other specs MUST be excluded unless they match another requested predicate

## Sources of Truth

- `cheatsheets/languages/sql.md` - Structured query concepts
- `cheatsheets/utils/ripgrep.md` - Text search contrast and fallback

