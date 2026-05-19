# testing Specification

@trace spec:testing

## Status

active

## Requirements

### Requirement: Local CI maps checks to traceable specs

Local CI scripts MUST map major check categories to owning specs so failures can be traced back to the behavior they protect.

#### Scenario: Rust test lane is selected

- **WHEN** local CI runs the Rust test lane
- **THEN** the lane MUST be associated with the testing spec
- **AND** failures MUST be reported with enough command context to reproduce locally

## Sources of Truth

- `cheatsheets/runtime/testing-best-practices.md` - Test methodology
- `cheatsheets/test/cargo-test.md` - Rust test execution

