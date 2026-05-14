<!-- @trace spec:podman-container-handle -->
# podman-container-handle Specification

## Status

active

## Purpose

Define the lightweight handle returned by the Podman wrapper after a launch
request succeeds. The handle SHALL carry the launch spec snapshot and the
runtime identity needed for stop, inspect, and event correlation.

## Requirements

### Requirement: Handle retains launch identity

The runtime SHALL return a typed handle that preserves the container name,
image reference, and spec snapshot used to create the container.

#### Scenario: Handle fields are inspectable
- **WHEN** a container launch succeeds
- **THEN** the returned handle exposes the name and image used to launch it
- **AND** the embedded spec can be inspected without rebuilding argv

### Requirement: Handle creation remains unit-testable

The handle layer SHALL remain a pure data boundary that can be constructed and
tested in isolation without invoking Podman or the network.

#### Scenario: Handle tests stay isolated
- **WHEN** unit tests construct a handle from a spec snapshot
- **THEN** the test does not need a live Podman daemon
- **AND** the handle can still be used as the identity for lifecycle code

### Requirement: Event stream maps back to handle identity

The runtime event stream SHALL use the same container identity that the handle
stores so lifecycle transitions can be matched deterministically.

#### Scenario: Event correlation stays stable
- **WHEN** `podman events` reports a state change for a container
- **THEN** the handle identity can be matched to the event stream
- **AND** no shell-side name reconstruction is required

## Litmus Chain

Agents iterating on the handle layer SHOULD start with the pure handle tests
before widening to the full podman orchestration chain:

1. `./scripts/run-litmus-test.sh podman-container-handle`
1. `./scripts/run-litmus-test.sh podman-container-spec`
1. `./scripts/run-litmus-test.sh podman-orchestration`
1. `./build.sh --ci --strict --filter podman-container-handle:podman-container-spec:podman-orchestration`
1. `./build.sh --ci-full --install --strict --filter podman-container-handle:podman-container-spec:podman-orchestration:security-privacy-isolation`
1. `tillandsias --init --debug`

## Sources of Truth

- `crates/tillandsias-podman/src/container_spec.rs`
- `crates/tillandsias-podman/src/launch.rs`
- `crates/tillandsias-podman/src/events.rs`
- `crates/tillandsias-podman/src/runtime.rs`
- `cheatsheets/runtime/testing-best-practices.md`

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus-podman-container-handle-shape`

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:podman-container-handle" crates/ openspec/ --include="*.rs" --include="*.md" --include="*.sh"
```
