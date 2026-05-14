<!-- @trace spec:podman-container-spec -->
# podman-container-spec Specification

## Status

active

## Purpose

Define the typed Rust container-spec layer used by Tillandsias to build
Podman launch arguments without shell strings. This layer is the isolated,
unit-testable boundary between launch intent and runtime execution.

## Requirements

### Requirement: Launch specs are typed and directly serialized

The runtime SHALL represent container launches as typed spec objects and SHALL
serialize them directly to Podman argv vectors. The spec layer MUST NOT require
shell interpolation.

#### Scenario: Spec serialization is direct
- **WHEN** a container spec is built for a forge or tray launch
- **THEN** the builder returns a deterministic argv vector
- **AND** the argv vector can be asserted in a unit test without launching Podman

### Requirement: Security defaults are immutable

The spec layer SHALL enable the Tillandsias baseline hardening defaults by
construction: `--init`, `--rm`, `--userns=keep-id`, `--cap-drop=ALL`,
`--security-opt=no-new-privileges`, and `--security-opt=label=disable`.

#### Scenario: Defaults remain present
- **WHEN** a new container spec is created
- **THEN** the hardening defaults are already present
- **AND** the builder does not expose a weakening path for those defaults

### Requirement: Spec layer supports launch-shape composition

The spec layer SHALL support detached mode, interactive mode, tty mode,
environment variables, bind mounts, volume mounts, Podman options, publish
flags, entrypoints, and trailing command arguments.

#### Scenario: Detached web profile is expressible
- **WHEN** a web-mode launch spec is created
- **THEN** it can express detached operation without `--rm`
- **AND** it still preserves the immutable hardening defaults

## Litmus Chain

Agents iterating on the spec layer SHOULD start with the pure builder tests
before widening to the tray/runtime call sites:

1. `./scripts/run-litmus-test.sh podman-container-spec`
1. `./scripts/run-litmus-test.sh podman-container-handle`
1. `./scripts/run-litmus-test.sh podman-orchestration`
1. `./build.sh --ci --strict --filter podman-container-spec:podman-container-handle:podman-orchestration`
1. `./build.sh --ci-full --install --strict --filter podman-container-spec:podman-container-handle:podman-orchestration:security-privacy-isolation`
1. `tillandsias --init --debug`

## Sources of Truth

- `crates/tillandsias-podman/src/container_spec.rs`
- `crates/tillandsias-podman/src/launch.rs`
- `crates/tillandsias-headless/src/tray/mod.rs`
- `cheatsheets/runtime/podman.md`
- `cheatsheets/runtime/container-lifecycle.md`
- `cheatsheets/runtime/testing-best-practices.md`

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus-podman-container-spec-shape`

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:podman-container-spec" crates/ openspec/ --include="*.rs" --include="*.md" --include="*.sh"
```
