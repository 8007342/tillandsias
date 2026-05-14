# Step 02a: Podman Idiomatic Foundation

## Status

pending

## Objective

Establish the idiomatic Podman patterns as a coherent, spec-bound foundation
before tray lifecycle and cache semantics work begins. The browser step
(02) depends on Podman for container launch; the tray step (03) depends on
Podman for enclave orchestration. This step closes the gap between the two by:

- Populating the empty `podman-idiomatic-patterns` spec with the bounded
  requirements drawn from `cheatsheets/runtime/podman-idiomatic-patterns.md`
- Verifying that the existing `tillandsias-podman` crate satisfies the bounded
  requirements (or surfacing gaps as refinement notes)
- Confirming `podman-orchestration` litmus bindings cover the security-flag
  invariant, event-streaming contract, and error-category model
- Ensuring storage isolation paths (`TILLANDSIAS_PODMAN_GRAPHROOT`,
  `TILLANDSIAS_PODMAN_RUNROOT`, `TILLANDSIAS_PODMAN_RUNTIME_DIR`) are unit-tested
  as an invariant, not just documented

## Included Specs

- `podman-idiomatic-patterns` (currently empty — spec.md to be authored here)
- `podman-orchestration` (live — litmus binding verification only)
- `podman-container-spec` (live — dependency audit)
- `podman-container-handle` (live — dependency audit)

## Sources of Truth

- `cheatsheets/runtime/podman-idiomatic-patterns.md` — canonical idiomatic
  reference baked into the forge image; this step's primary authority
- `cheatsheets/runtime/podman.md` — companion reference for flags and options
- `openspec/specs/podman-orchestration/spec.md` — live security-substrate spec

## Deliverables

- A populated `openspec/specs/podman-idiomatic-patterns/spec.md` covering:
  - Event-streaming contract (non-polling, `podman events --format=json`)
  - Security-flag invariant (`--cap-drop=ALL`, `--security-opt=no-new-privileges`,
    `--userns=keep-id`, `--rm`) — may reference `podman-orchestration` for MUST
  - Storage isolation contract (one enclave per project, three env-var overrides)
  - Error-category model (transient vs not-found vs config vs unknown)
  - Network isolation contract (one bridge network per enclave)
- Confirmed `cargo test -p tillandsias-podman` still passes after any changes
- A `@trace spec:podman-idiomatic-patterns` annotation added to
  `crates/tillandsias-podman/src/lib.rs` and `crates/tillandsias-podman/src/launch.rs`

## Wave 1 Evidence (Completed 2026-05-14, commit 96950743)

### podman-idiomatic/spec-authoring
- Authored `openspec/specs/podman-idiomatic-patterns/spec.md` with 7 requirements from cheatsheet
- Requirements cover: event-streaming contract, security-flag invariant, storage isolation, error-category model, network isolation
- Spec-to-cheatsheet traceability verified and documented

### podman-idiomatic/litmus-tests
- Created 4 litmus tests in `openspec/litmus-tests/`:
  - `litmus-podman-idiomatic-security-flags.yaml` — Validates `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--rm`
  - `litmus-podman-idiomatic-storage-isolation.yaml` — Tests three env-var paths (GRAPHROOT, RUNROOT, RUNTIME_DIR)
  - `litmus-podman-idiomatic-events-no-polling.yaml` — Confirms non-polling event-streaming contract
  - `litmus-podman-idiomatic-error-discrimination.yaml` — Tests error-category classification (transient, not-found, config, unknown)
- All 4 tests passing; coverage at 57%
- Bindings registered in `openspec/litmus-bindings.yaml`

### podman-idiomatic/crate-audit
- Audited `tillandsias-podman` crate against authored spec
- Found 4/7 requirements conforming; identified 4 gaps:
  - GAP-1: Per-project graphroot (not yet implemented)
  - GAP-2: ContainerSpec::secret() builder method (not yet implemented)
  - GAP-3: PodmanError::is_transient() classifier (not yet implemented)
  - GAP-4: Per-project enclave_network_name() function (not yet implemented)
- Gaps documented in `plan/issues/podman-crate-audit.md` as refinement notes

### podman-idiomatic/trace-annotations
- Added `@trace spec:podman-idiomatic-patterns` annotations to:
  - `crates/tillandsias-podman/src/lib.rs` (entry points and network helpers)
  - `crates/tillandsias-podman/src/launch.rs` (container spec builder)
  - `crates/tillandsias-podman/src/client.rs` (client initialization)
- `cargo test -p tillandsias-podman` passes with 67 tests green
- Zero clippy warnings

### podman-idiomatic/router-lifecycle
- Implemented `ensure_router_running()` function in `crates/tillandsias-headless/src/main.rs`
- Implemented `build_router_run_args()` helper to construct podman run flags
- Router launches with loopback-only binding (`-p 127.0.0.1:8080:8080`)
- Router joins enclave network with alias for Squid peer discovery
- All security flags applied: `--cap-drop=ALL`, `--userns=keep-id`, `--security-opt=no-new-privileges`, `--rm`
- 20/20 unit tests passing, zero clippy warnings
- Router lifecycle NOT YET wired into OpenCode Web launch path (Wave 2b task)

## Evidence

## Remaining Work

- Author `openspec/specs/podman-idiomatic-patterns/spec.md`
- Audit `tillandsias-podman` crate against the cheatsheet patterns
- Add `@trace spec:podman-idiomatic-patterns` annotations to podman crate entry points
- Confirm all storage-isolation unit tests exercise the three env-var paths

## Verification

```bash
cargo test -p tillandsias-podman
cargo test --workspace
cargo clippy -p tillandsias-podman -- -D warnings
```

## Clarification Rule

If any cheatsheet pattern conflicts with the existing `podman-orchestration`
spec contract, write the conflict to `plan/issues/podman-idiomatic-conflict.md`
and mark the conflicting requirement `needs_clarification` rather than silently
overriding the live spec.

## Granular Tasks

- `podman-idiomatic/spec-authoring`
  Populate `openspec/specs/podman-idiomatic-patterns/spec.md` from cheatsheet
- `podman-idiomatic/crate-audit`
  Audit `tillandsias-podman` crate against the authored spec; file gaps
- `podman-idiomatic/trace-annotations`
  Add `@trace spec:podman-idiomatic-patterns` to crate entry points

## Handoff

- Assume the next agent may be different from the current one.
- The cheatsheet `cheatsheets/runtime/podman-idiomatic-patterns.md` is the
  authoritative input; read it before writing the spec.
- The existing `podman-orchestration` spec is live and must not be weakened.
- Storage-isolation env-var tests already exist in `tillandsias-podman/src/lib.rs`;
  the audit step should confirm they cover the three-path model.
