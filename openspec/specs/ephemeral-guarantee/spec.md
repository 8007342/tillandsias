<!-- @trace spec:ephemeral-guarantee -->
# ephemeral-guarantee Specification

## Identity

- **Name**: ephemeral-guarantee
- **Status**: current
- **Owner**: linux-runtime

## Authority

Runtime substrate is ephemeral by design: everything created for execution sessions,
expert servers, build caches, and diagnostic streams must be ephemeral, recoverable,
or strictly isolated from persistent source state (`methodology/philosophy.yaml` ephemerality invariant).

The system enforces:
1. Complete recreation of runtime state over hand-patching.
2. Disjointness between persistent cache volumes and ephemeral runtime state.
3. Zero lingering runtime or expert artifacts post container/stack termination.

## Purpose

Prevent state pollution, cross-session leakage, and unverified persistence by formalizing
the ephemerality invariants governing forge experts, tmpfs allocations, container lifecycles,
and diagnostic log lifecycles.

## Requirements

### Requirement: Ephemeral Expert State and Binary Surfaces
<!-- req-id: 5c90e9a5 -->

Forge expert runtime state MUST be allocated in a tmpfs filesystem (`/dev/shm`), and expert binaries MUST be located strictly within the auto-removed container overlay filesystem (`$HOME/.local/bin`), with container launch specifying `--rm` and no `.persistent()` attribute.

### Requirement: Persistent Volume Disjointness
<!-- req-id: 47aa3c93 -->

No expert liveness or state surface (`state`, `started_at`, `plan-source-hash`, `project-index`) MAY reside under any path mounted to a persistent volume (such as `/home/forge/.cache/tillandsias-project`).

### Requirement: Containment of Build-Cache Carve-Out
<!-- req-id: c926a17c -->

The persistent Cargo build cache (`$CARGO_TARGET_DIR`) is permitted for build compilation artifacts only; expert executables MUST be copied out into the ephemeral bin directory (`$HOME/.local/bin`) prior to invocation, never executed directly from the persistent cache volume.

### Requirement: Read-Only Named Volume for Content-Addressed Spec Index
<!-- req-id: 08f73ace -->

The spec RAG index volume (`tillandsias-spec-index-<project>`) MUST be mounted `ReadOnly` at `/opt/tillandsias/spec-index`, separate from read-write caches, with matching const injection (`FORGE_SPEC_INDEX_MOUNT`).

### Requirement: Zero Artifact Persistence Post-Teardown
<!-- req-id: a6bf2550 -->

Following stack container termination, the persistent project cache volume and host `/dev/shm` MUST contain zero expert state files or plan-source stamps, verified against an intact positive control marker.

### Requirement: Ephemeral Initialization and Diagnostic Log Lifecycle
<!-- req-id: c2bd97fb -->

Initialization and debug logs written to `/tmp` MUST be deleted upon successful startup without persisting across reboots or session launches.

## Sources of Truth

- `cheatsheets/architecture/expert-inference-endpoint-contract.md`
- `cheatsheets/tooling/podman.md`
- `methodology/philosophy.yaml`
