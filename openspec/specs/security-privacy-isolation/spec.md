<!-- @trace spec:security-privacy-isolation -->
# security-privacy-isolation Specification

## Status

active

## Purpose

Define the zero-tolerance security, privacy, and isolation boundaries that
govern all current Tillandsias runtime paths. This spec is the top-level
entrypoint for agent work that needs a current answer to: "what must never
leak, escape, or silently weaken?"

## Requirements

### Requirement: Zero-tolerance credential boundary

The runtime SHALL never expose host credentials, secret material, or native
keyring access to forge, terminal, browser, or proxy containers except through
the specific credential transports named by the owning secrets specs. Token
material MAY exist only as ephemeral host-side artifacts or read-only mounts
defined by the credential specs.

#### Scenario: Forge and terminal containers remain credential-free
- **WHEN** a forge or terminal container is launched
- **THEN** no secret mount, token file, or keyring handle is attached
- **AND** no credential value appears in logs or environment variables

#### Scenario: Git service receives the only token transport
- **WHEN** a git service container is launched with credentials
- **THEN** the only credential material allowed is the read-only token transport
- **AND** the transport MUST match `spec:secrets-management` and
  `spec:native-secrets-store`

### Requirement: Zero-tolerance runtime leakage boundary

The shipped runtime SHALL not leak host runtime state into containers beyond
the explicitly documented runtime seams. Host D-Bus, host home directories,
host Podman sockets, and host-specific paths MUST NOT be inherited by default.

#### Scenario: Container launch uses only intended runtime seams
- **WHEN** the runtime launches a container
- **THEN** only the documented runtime directories and sockets are used
- **AND** any host path leak is treated as a boundary failure

### Requirement: Zero-tolerance network boundary

Containers SHALL not bypass the proxy/enclave model for ordinary runtime
traffic. Direct egress is forbidden unless a spec explicitly names a debug or
standalone exception.

#### Scenario: Forge traffic is proxied
- **WHEN** a forge container makes HTTP or HTTPS requests
- **THEN** the requests SHALL traverse the enclave proxy
- **AND** no direct internet route is assumed

#### Scenario: Browser isolation stays isolated
- **WHEN** browser isolation launches a user-facing browser container
- **THEN** the container SHALL use the browser isolation spec boundary
- **AND** browser behavior MUST remain separate from forge behavior

### Requirement: Zero-tolerance shell-wrapper boundary

The shipped runtime SHALL use compiled Rust and direct Podman calls for user
facing orchestration. Repository shell scripts MAY remain as developer tooling,
but they MUST NOT be the runtime execution path. Interactive terminal launches
MAY invoke a terminal emulator, but they MUST hand it `podman` plus argv
directly instead of constructing shell-escaped command strings.

#### Scenario: Runtime launch uses compiled code
- **WHEN** the runtime launches a container or performs lifecycle work
- **THEN** it SHALL use compiled Rust control flow
- **AND** it SHALL NOT shell out to repo scripts for the ordinary path
- **AND** interactive tray launches SHALL not depend on shell interpolation for Podman argv

### Requirement: Security hardening defaults are immutable

The baseline container security contract SHALL remain non-negotiable:
`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, and
`--security-opt=label=disable` remain the default safety envelope for the
documented launch profiles.

#### Scenario: Launch profile drift is rejected
- **WHEN** a launch profile weakens the hardening flags
- **THEN** the weakened option is ignored or replaced
- **AND** the change is treated as a security regression

## Litmus Chain

Agents working this spec SHOULD start with the smallest boundary test and then
expand outward:

1. `./scripts/run-litmus-test.sh security-privacy-isolation`
1. `./scripts/run-litmus-test.sh native-secrets-store`
1. `./scripts/run-litmus-test.sh secrets-management`
1. `./scripts/run-litmus-test.sh environment-runtime`
1. `./scripts/run-litmus-test.sh enclave-network`
1. `./scripts/run-litmus-test.sh podman-container-spec`
1. `./scripts/run-litmus-test.sh podman-container-handle`
1. `./scripts/run-litmus-test.sh podman-orchestration`
1. `./build.sh --ci --strict --filter native-secrets-store:secrets-management:environment-runtime:enclave-network:podman-container-spec:podman-container-handle:podman-orchestration`
1. `./build.sh --ci-full --install --strict --filter native-secrets-store:secrets-management:environment-runtime:enclave-network:podman-container-spec:podman-container-handle:podman-orchestration`
1. `tillandsias --init --debug`

## Sources of Truth

- `openspec/specs/native-secrets-store/spec.md`
- `openspec/specs/secrets-management/spec.md`
- `openspec/specs/environment-runtime/spec.md`
- `openspec/specs/enclave-network/spec.md`
- `openspec/specs/podman-container-spec/spec.md`
- `openspec/specs/podman-container-handle/spec.md`
- `openspec/specs/podman-orchestration/spec.md`
- `openspec/specs/browser-isolation-tray-integration/spec.md`
- `cheatsheets/runtime/podman.md`
- `cheatsheets/runtime/runtime-logging.md`
- `cheatsheets/runtime/browser-isolation.md`

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:credential-isolation`
- `litmus:environment-isolation`
- `litmus:enclave-isolation`
- `litmus:socket-cleanup`
- `litmus:podman-build-command-shape`
- `litmus:podman-web-launch-profile`

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:security-privacy-isolation" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
