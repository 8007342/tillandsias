# Headless Mode Specification

## Status

status: active
promoted_from: direct
annotation_count: 4

## Purpose

Define the contract for running Tillandsias without a graphical user interface. Headless mode emits structured JSON events to stdout and is suitable for CI/CD automation, server deployments, and containerized environments. Headless mode must not depend on GTK or display subsystems, ensuring portability and composability.

## Requirements

### Requirement: Headless binary invocation with --headless flag

The binary MUST accept the `--headless` flag to explicitly run in headless mode without attempting to initialize any graphical interface.

#### Scenario: --headless flag enables headless mode

- **WHEN** the binary is invoked with `tillandsias --headless [config_path]`
- **THEN** the application MUST enter headless mode (no GTK window created)
- **AND** the Tokio async runtime MUST be initialized
- **AND** configuration MUST be loaded from the provided path (if specified)
- **AND** the main event loop MUST start without blocking on display initialization

#### Scenario: startup event emitted on successful launch

- **WHEN** the headless application successfully initializes
- **THEN** a JSON event MUST be emitted to stdout: `{"event":"app.started","timestamp":"<RFC3339>"}`
- **AND** the timestamp MUST be in RFC3339 format (e.g., `2026-05-15T10:30:45.123456-07:00`)
- **AND** the event MUST be immediately flushed to stdout (not buffered)

#### Scenario: graceful shutdown with stopped event

- **WHEN** the headless application receives SIGTERM or SIGINT signal
- **THEN** the signal handler MUST initiate graceful shutdown sequence
- **AND** background metric sampler MUST be cancelled before container teardown
- **AND** all containers MUST be stopped with configurable timeout (default 30s)
- **AND** a final JSON event MUST be emitted: `{"event":"app.stopped","exit_code":0,"timestamp":"<RFC3339>"}`
- **AND** the process MUST exit with code 0 on successful shutdown

### Requirement: Container status events and metrics reporting

During headless operation, the application MUST emit JSON events documenting container and system state at appropriate intervals.

#### Scenario: containers.running event reports container count

- **WHEN** the headless application discovers running containers via podman
- **THEN** a JSON event MUST be emitted: `{"event":"containers.running","count":N,"timestamp":"<RFC3339>"}`
- **AND** the count N MUST accurately reflect the number of containers currently running for the project
- **AND** the event MUST be emitted once during initialization and whenever container state changes

#### Scenario: JSON output is well-formed and parseable

- **WHEN** the application emits JSON events to stdout
- **THEN** each JSON event MUST be valid JSON that parses without error
- **AND** each event MUST contain an `"event"` field (string) identifying the event type
- **AND** each event MUST contain a `"timestamp"` field (RFC3339 string) documenting when the event occurred
- **AND** optional additional fields MUST be documented in the event schema (e.g., `count`, `exit_code`)

### Requirement: No GTK dependency in headless path

The headless code path MUST NOT initialize GTK or attempt to interact with any display subsystem. This ensures the binary remains portable to headless environments.

#### Scenario: GTK conditional compilation avoided in headless path

- **WHEN** the binary is compiled with or without the `tray` feature
- **THEN** the headless code path MUST NOT import or reference GTK libraries
- **AND** GTK-related code (spawn_tray_window, is_tray_available) MUST only be reached if the `tray` feature is enabled
- **AND** the headless path MUST be reachable and functional without any GTK dependencies

#### Scenario: Auto-detection falls back to headless when GTK unavailable

- **WHEN** the binary is invoked without flags (auto-detection mode)
- **AND** GTK is not available in the environment (e.g., in a container or headless OS)
- **THEN** the application MUST automatically fall back to headless mode
- **AND** no error about missing GTK MUST be displayed
- **AND** the application MUST proceed with normal operation in headless mode

### Requirement: Status-check mode for initialization verification

The `--status-check` flag MUST enable a lightweight initialization verification mode that validates the runtime environment without running the full event loop.

#### Scenario: --status-check verifies services and exits

- **WHEN** the binary is invoked with `tillandsias --status-check`
- **THEN** the initialization path MUST be executed (container discovery, image validation, etc.)
- **AND** a representative stack smoke test MUST be run (per usage documentation)
- **AND** the process MUST exit with code 0 if all checks pass
- **AND** the process MUST exit with code 1 if any check fails
- **AND** the main headless event loop MUST NOT be started

#### Scenario: --init combined with --status-check pre-builds and verifies

- **WHEN** the binary is invoked with `tillandsias --init --status-check`
- **THEN** container images MUST be pre-built (per --init behavior)
- **AND** initialization verification MUST be run after images are built
- **AND** exit code MUST reflect the combined result (success only if both steps succeed)

## Invariants

- **No GTK in headless**: GTK/Adwaita imports and initialization code MUST NOT be reachable in headless mode without the `tray` feature.
- **JSON event stream**: All events emitted to stdout MUST be valid JSON with consistent field structure (event, timestamp, optional context fields).
- **Async runtime**: Headless mode MUST initialize Tokio runtime; all async operations MUST be awaited or spawned, never blocked.
- **Signal safety**: SIGTERM/SIGINT handlers MUST be registered before the main event loop starts; signals MUST be processed safely without memory corruption.
- **Graceful shutdown**: All containers MUST be stopped with configurable timeout; metrics sampler MUST be cancelled before container teardown to avoid race conditions.
- **Configuration isolation**: If config_path is provided, it MUST be loaded before initialization; if config_path is not provided, defaults MUST be used.

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:binary-e2e-smoke` — Full end-to-end smoke test exercising headless startup, event emission, and graceful shutdown

## Sources of Truth

- `cheatsheets/runtime/portable-executable-transparent-mode.md` — Three-tier mode system (headless, tray, auto-detect) and compilation strategy
- `cheatsheets/runtime/logging-levels.md` — JSON event structure, timestamp formatting, and observability integration
- `cheatsheets/runtime/event-driven-monitoring.md` — Event loop patterns and signal handling in async contexts

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:headless-mode" crates/ tests/ --include="*.rs"
```

Key implementation files:
- `crates/tillandsias-headless/src/main.rs` — Main entry point, mode detection, and headless runtime
- `crates/tillandsias-headless/tests/e2e_user_flow.rs` — End-to-end tests for JSON event emission and signal handling
