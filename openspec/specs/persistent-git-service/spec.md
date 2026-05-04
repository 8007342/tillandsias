<!-- @trace spec:persistent-git-service -->
# persistent-git-service Specification

## Status

status: active
promoted-from: openspec/changes/archive/2026-04-16-persistent-git-service/
annotation-count: 0
implementation-complete: false

## Purpose

Keep the per-project git-service container alive across forge launches within a single tray session. This eliminates the 3-4 second rebuild cost on every "Attach Here" after the user closes their previous development environment, improving warm-launch latency on Windows.

## Requirements

### Requirement: Tray-Session Scoped Git Service Lifetime

The git-service container MUST be started lazily on first "Attach Here" for a project (unchanged) and MUST be kept alive across all subsequent forge launches for that project within the same tray session.

#### Scenario: First attach to a project
- **WHEN** user clicks "Attach Here" for a project that has no running git-service
- **THEN** the git-service container is created, started, and remains running

#### Scenario: Forge exits, user reattaches to same project
- **WHEN** user closes the forge terminal and then clicks "Attach Here" again for the same project
- **THEN** the existing git-service is reused without rebuild (image staleness check skipped)

#### Scenario: Application shutdown
- **WHEN** the tray application exits
- **THEN** all git-service containers are collected from `state.running` and stopped
- **THEN** no git-service is tied to individual forge lifetime

### Requirement: Event Loop No Longer Stops Git Service

The event loop trigger that stops the git-service container when the last forge for a project exits MUST be removed.

#### Scenario: Last forge exits
- **WHEN** the last forge or maintenance container for a project exits
- **THEN** the git-service remains running (no lifecycle coupling)

### Requirement: Shutdown Collects Git Services by Project

The `handlers::shutdown_all` function MUST collect git-service project names from `state.running` rows where `container_type == GitService`, rather than deriving them from active forge projects.

#### Scenario: Tray shutdown with orphaned git services
- **WHEN** the tray is shutting down
- **THEN** any git-service found in `state.running` is stopped, regardless of whether its project has active forges

## Rationale

The git-service is architecturally similar to the proxy and inference services: it is enclave infrastructure, project-scoped, and stateless apart from the on-disk mirror cache (which persists anyway). The ~10 MB RAM per project is negligible compared to the 3-4 second latency cost of rebuilding on every reattach. This change removes the defensive coupling and delivers measurable warm-launch improvement, especially on Windows.

## Sources of Truth

- `cheatsheets/runtime/podman.md` — podman container lifecycle, state transitions, and long-lived container management
- `cheatsheets/utils/git-workflows.md` — git repository operations, mirror repositories, and stateless git service design
- `cheatsheets/runtime/networking.md` — enclave networking, container communication, and port exposure

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Git service cleanups are verified; no orphaned repos or mirrors
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable
