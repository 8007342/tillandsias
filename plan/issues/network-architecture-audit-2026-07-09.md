# Network Architecture Audit — Runtime Taxonomy & End-to-End Design

**Date:** 2026-07-09
**Classification:** audit+design
**Host:** any
**Observed by:** linux-big-pickle-20260709

## Observation

The networking stack has grown organically across multiple runtimes (HOST, GUEST,
CONTAINER, COMPILE/BUILD) without a unifying architectural document. Each runtime
has different requirements — enclave isolation, proxy egress, direct podman access,
host-network builds — but they share the same code paths and configuration surface.
This has led to:

1. **Missing vault image in `--init` builds** (order 244 was a symptom): vault image
   is built on-demand rather than as part of the declarative image set, and its build
   happens in the user-runtime path rather than the init/build-runtime path.

2. **HTTP 401 from `gh auth login` inside git-login container** (2026-07-09): the
   proxy-routed auth request to `api.github.com` fails with Bad Credentials. Root
   cause may be proxy header injection, allowlist gap, DNS resolution order, or
   TLS interception (CA bundle missing/expired in container).

3. **Vault rebuilds on repeated login attempts**: the vault container/image is
   sometimes rebuilt when re-running `--github-login`, indicating the init/build
   caching boundary is unclear between user-runtime and build-runtime.

4. **No declared network scenarios**: the codebase has no explicit taxonomy of
   which network topology applies to which runtime mode.

## Impact

`--github-login` is unreliable on the primary Linux development host. Debugging is
slow because the network topology is implicit — every debug run requires tracing
through podman networks, proxy config, vault secrets, and the container dependency
graph without a reference architecture.

## Required Agents

At least 3 agents must verify this packet as complete:
- `opencode-bigpickle`
- `antigravity-gemini`
- `codex-gpt55-highthink`

## Deliverable

A ratified network architecture document covering:

1. **Runtime Taxonomy Table**: HOST, GUEST (WSL2/macOS-VZ/Toolbox),
   CONTAINER (forge/proxy/vault/inference/git/router), COMPILE/BUILD — each
   with its network topology, egress rules, DNS config, proxy awareness, and
   podman capabilities.

2. **Network Scenarios Catalog**: For each runtime, the set of valid network
   topologies (enclave-internal, enclave+egress, host-network, none) and which
   scenario applies to which operation (init, login, forge, cloud project,
   diagnostics).

3. **Dependency Graph Awareness**: How `container_deps.rs` must account for
   runtime context — e.g., BUILD runtime should not require vault; GUEST runtime
   needs different proxy paths.

4. **Platform Abstraction Layer**: For each HOST platform (Linux bare, WSL2,
   macOS VZ, Silverblue Toolbox), the network bridge/forwarding mechanism used
   and how it maps to the runtime topology.

5. **Spec/Cheatsheet Patch List**: Specific files in `openspec/specs/` and
   `docs/cheatsheets/` that need updating to reflect the ratified architecture.
