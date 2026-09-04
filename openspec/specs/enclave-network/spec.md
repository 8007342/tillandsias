<!-- @trace spec:enclave-network -->
# enclave-network Specification

## Status

active

## Purpose

Internal podman network that isolates every Tillandsias-managed container. Only the proxy is dual-homed for external access; all other members communicate exclusively through the enclave.

The membership set is NOT enumerated here in prose. It is defined by the run-argument builders listed under *Container attachment to enclave network* below, and `scripts/check-enclave-membership-documented.sh` refuses any attach site those do not name. A hand-maintained prose list went stale by SIX members between 2026-07 and 2026-08-30 (order 245 P8) — it still said "forge, git, inference, and proxy" after vault, the router, the nix cache, the catalog service, the observatorium web and the ssh-lane sidecar had all joined. The sixth was found by the guard, not by the hand audit that preceded it, because the enclave is named by THREE constants (`ENCLAVE_NET`, `ENCLAVE_ONLY_NET`, `ENCLAVE_EGRESS_NETS`) and a manual sweep covered two.

## Requirements

### Requirement: Internal podman network for container isolation
<!-- req-id: 1310793a -->
The system MUST create and manage a podman internal network named `tillandsias-enclave` that prevents containers attached to it from reaching external networks directly. The network MUST be created on first container launch and persist until the application exits. The network MUST be reused if already present.

@trace spec:enclave-network

#### Scenario: First container launch creates enclave network
- **WHEN** a container is launched and the `tillandsias-enclave` network does not exist
- **THEN** the system MUST create it with `podman network create tillandsias-enclave --internal`
- **AND** log the creation via `--log-enclave` with `@trace spec:enclave-network`

#### Scenario: Enclave network already exists
- **WHEN** a container is launched and the `tillandsias-enclave` network already exists
- **THEN** the system MUST reuse the existing network without error

#### Scenario: Enclave network cleanup on app exit
- **WHEN** the Tillandsias application exits
- **AND** no containers are attached to the `tillandsias-enclave` network
- **THEN** the system MUST remove the network with `podman network rm tillandsias-enclave`

#### Scenario: Enclave network cleanup skipped when containers active
- **WHEN** the Tillandsias application exits
- **AND** containers are still attached to the `tillandsias-enclave` network
- **THEN** the system MUST log a warning and leave the network in place

### Requirement: Container attachment to enclave network
<!-- req-id: c29af806 -->
The system MUST attach every Tillandsias-managed container to the `tillandsias-enclave` network. Only the proxy MUST additionally be attached to the egress network for external access.

The attach sites are these run-argument builders, named by SYMBOL so the list survives every edit that does not rename one (order 245 P8; the same anchoring order 881-29me requires of audit citations):

- `main.rs` `fn build_proxy_run_args` — the only dual-homed member (`ENCLAVE_EGRESS_NETS`)
- `main.rs` `fn build_git_run_args` — enclave-only since order 606-9wqd (`ENCLAVE_ONLY_NET`)
- `main.rs` `fn build_ssh_lane_sidecar_run_args` — enclave-only
- `main.rs` `fn build_inference_run_args`
- `main.rs` `fn build_router_run_args`
- `main.rs` `fn build_nix_cache_run_args` (order 801-vm4p; also launched by `scripts/nix-cache-service.sh`)
- `main.rs` `fn build_catalog_service_run_args`
- `main.rs` `fn build_observatorium_web_args`
- `main.rs` `fn build_opencode_forge_args`
- `main.rs` `fn build_forge_agent_run_args_with_vault`
- `main.rs` `fn build_stack_common_args` — the shared prefix, not a service of its own
- `vault_bootstrap.rs` `fn launch_vault_container`

A new enclave member MUST be added to this list in the same commit that attaches it; `scripts/check-enclave-membership-documented.sh` refuses the divergence in both directions.

@trace spec:enclave-network

#### Scenario: Forge container attached to enclave only
- **WHEN** a forge container is launched
- **THEN** it MUST be attached to the `tillandsias-enclave` network via `--network=tillandsias-enclave`
- **AND** it MUST NOT have access to the default bridge network

#### Scenario: Proxy container is dual-homed
- **WHEN** the proxy container is launched
- **THEN** it MUST be attached to both the `tillandsias-enclave` network and the default bridge network
- **AND** it MUST be reachable from enclave containers at hostname `proxy`

### Requirement: Enclave lifecycle telemetry
<!-- req-id: 7213c628 -->
All enclave network operations MUST be logged to the `--log-enclave` accountability window with lifecycle events only (no secrets, no context params). Each event MUST include a clickable `@trace` link.

@trace spec:enclave-network

#### Scenario: Network creation logged
- **WHEN** the enclave network is created
- **THEN** the system MUST log `[enclave] Network created: tillandsias-enclave` with `@trace spec:enclave-network`

#### Scenario: Container attachment logged
- **WHEN** a container is attached to the enclave network
- **THEN** the system MUST log `[enclave] Container attached: <name>` with `@trace spec:enclave-network`

## Sources of Truth

- `cheatsheets/runtime/networking.md` — Networking reference and patterns
- `cheatsheets/runtime/podman.md` — Podman reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:enclave-isolation`
- `litmus:socket-cleanup`

Gating points:
- Enclave network is isolated; no egress to host network without proxy
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:enclave-network" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
