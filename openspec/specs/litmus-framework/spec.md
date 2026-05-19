# litmus-framework Specification

@trace spec:litmus-framework

## Status

active

## Requirements

### Requirement: Litmus bindings remain falsifiable

Specs that declare litmus coverage MUST bind to checks that are deterministic, reproducible, and capable of failing when the claimed behavior regresses.

#### Scenario: Litmus check fails on missing evidence

- **WHEN** a litmus binding references a missing or skipped verification command
- **THEN** the methodology tooling MUST surface the missing evidence
- **AND** the spec MUST NOT be treated as fully verified

## Sources of Truth

- `cheatsheets/runtime/testing-best-practices.md` - Test quality expectations
- `cheatsheets/test/cargo-test.md` - Rust test execution reference

