# Headless Mode Specification

## Status

status: active
promoted_from: direct
annotation_count: 4

## Purpose

Define the contract for running Tillandsias without a graphical user interface. Headless mode emits structured JSON events to stdout and is suitable for CI/CD automation, server deployments, and containerized environments. Headless mode must not depend on GTK or display subsystems, ensuring portability and composability.

## Requirements

### Requirement: Headless binary invocation with --headless flag
<!-- req-id: 271168ba -->

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
<!-- req-id: 9db538a6 -->

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
<!-- req-id: 5b2d011a -->

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
<!-- req-id: 18c2e89a -->

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


### Requirement: Per-operation image ensure lists, and the Build-context vault
<!-- req-id: fc3923e5 -->

Every headless operation that starts containers MUST ensure the images it will
start, before starting them. The lists are DELIBERATELY per-operation subsets,
not one shared set, and MUST NOT be unified.

`main.rs` `fn ensure_versioned_images` is the single mechanism; the lists that
feed it are the per-operation part:

| operation | symbol | ensures |
|---|---|---|
| init / Build context | `fn run_init` | ten images, `"vault"` THIRD after `"proxy"` and `"git"` |
| proxy bring-up | `fn ensure_proxy_running` | `proxy` only |
| status check | `fn run_status_check` | proxy, git, inference, chromium-core, chromium-framework, forge, router, web |
| observatorium | `fn run_observatorium_mode` | web, router, chromium-core, chromium-framework |
| OpenCode CLI lane | `fn run_opencode_mode` | proxy, router, git, inference, forge |
| cold forge launch | `fn ensure_enclave_for_project` | router, git, inference, forge |

**`vault` appears in the init list and in NO per-operation list, and that is
order 253's design, not an omission.** Vault belongs to the init/Build context;
`vault_bootstrap.rs` `fn build_vault_image` early-returns when the init-built
identity tag exists, so a login on an initialized runtime is zero-build and the
on-demand build survives only as a fail-soft fallback for runtimes that skipped
`--init`. `nix-cache` likewise appears in no ensure list: it is reached through
the ForgeLaunch dependency graph (`container_deps.rs` `Service::NixCache`,
order 801-vm4p), not through `ensure_versioned_images`.

**Why unification would be wrong.** The lists differ because the operations
start different containers; merging them would make every lane pay for every
image. The risk they carry is the opposite one — an INCOMPLETE list — and it
fails obscurely: when `router` and `web` were missing from every ensure list,
the publish path hit a phantom registry pull (exit 125) on any version
handover (2026-07-16, recorded at the `run_status_check` list). An operation
that starts a container it did not ensure does not report a missing image; it
reports a registry failure.

@trace spec:headless-mode, order:245, order:253

#### Scenario: An operation ensures every image it starts
- **WHEN** a headless operation starts a container
- **THEN** that container's image MUST appear in the operation's own ensure
  list, or be ensured for it through the `container_deps` dependency graph
- **AND** the failure mode of getting this wrong is a phantom registry pull
  (125), not a named missing-image error — so the list is verified against what
  the operation STARTS, never against another operation's list

#### Scenario: Vault is not ensured per-operation
- **WHEN** a per-operation ensure list is written or extended
- **THEN** `vault` MUST NOT be added to it
- **AND** the init/Build context owns the vault build (order 253), with the
  login-path build kept only as a fail-soft fallback for runtimes that never
  ran `--init`

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
