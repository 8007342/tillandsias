## MODIFIED Requirements

### Requirement: Runtime abstraction across podman and WSL backends

The `tillandsias-podman` crate (or its successor `tillandsias-runtime`) SHALL expose a `Runtime` trait that abstracts over container/distro lifecycle and execution. Two implementations SHALL exist: `PodmanRuntime` (Linux + macOS) and `WslRuntime` (Windows). Every consumer in the workspace SHALL go through the trait; no direct `podman_cmd*()` invocations SHALL remain in `src-tauri/src/`. Direct podman primitives MAY remain inside `PodmanRuntime`'s implementation; they SHALL NOT leak through the trait.

> Delta: today the crate exposes `podman_cmd()` and `podman_cmd_sync()` directly to consumers. This is replaced by a trait-based facade. Backwards compatibility is provided for one release cycle by re-exporting the old helpers; consumers SHOULD migrate during that cycle.

#### Scenario: trait covers spec-mandatory operations

- **WHEN** the codebase compiles against `Runtime`
- **THEN** the trait surface includes at minimum: `image_exists`, `image_export_to_tar`, `service_create`, `service_start`, `service_stop`, `service_running`, `service_exec`, `service_remove`, `events_stream`, `list_services`, `service_address`

#### Scenario: no podman calls outside the runtime crate

- **WHEN** `grep -rn "podman_cmd\|podman_cmd_sync" src-tauri/` is run after Phase 1 of windows-wsl-runtime
- **THEN** no matches are found in `src-tauri/src/`
- **AND** matches in `crates/tillandsias-podman/src/runtime/podman.rs` are expected and acceptable
