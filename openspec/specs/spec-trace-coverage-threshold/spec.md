# spec-trace-coverage-threshold Specification

@trace spec:spec-trace-coverage-threshold

## Status

active

## Requirements

### Requirement: Trace coverage checks report threshold status

Trace validation tooling MUST compute trace coverage and compare it to the configured threshold without mutating repository state.

#### Scenario: Coverage is below threshold

- **WHEN** coverage is lower than the configured threshold
- **THEN** the validator MUST report the measured percentage and threshold
- **AND** it MUST exit non-zero unless warn-only behavior was explicitly requested

## Sources of Truth

- `cheatsheets/runtime/testing-best-practices.md` - Test gate behavior
- `cheatsheets/runtime/cheatsheet-lifecycle.md` - Documentation lifecycle context

