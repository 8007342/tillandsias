# cache-isolation Specification

@trace spec:cache-isolation

## Status

active

## Requirements

### Requirement: Durable cache and project state remain separated

Cache layers MAY be reused across projects only when they contain tool or dependency artifacts that are independent of project secrets and working tree state.

#### Scenario: Cache loss does not delete project state

- **WHEN** a cache directory, image cache, or overlay cache is deleted
- **THEN** the project workspace and durable project metadata MUST remain recoverable
- **AND** the next launch MUST rebuild missing cache artifacts instead of treating cache deletion as data loss

## Sources of Truth

- `cheatsheets/runtime/cache-architecture.md` - Cache boundary model
- `cheatsheets/runtime/forge-cache-semantics.md` - Forge cache semantics
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` - Durable vs ephemeral paths

