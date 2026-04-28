## ADDED Requirements

### Requirement: Windows runtime backend is WSL, not podman

On `target_os = "windows"`, Tillandsias SHALL drive enclave services through `wsl.exe` and the `Runtime` trait's `WslRuntime` backend. No `podman.exe` process SHALL be required to run on the Windows host after first-launch image extraction. The tray, CLI, and tests SHALL consume the `Runtime` trait, not platform-specific runtime APIs. The Linux/macOS code path SHALL continue to use `PodmanRuntime` unchanged.

#### Scenario: Windows tray launch with no podman

- **GIVEN** a Windows host with WSL2 installed but no `podman.exe`
- **WHEN** the tray binary launches (post-Phase 9)
- **THEN** the tray's state machine reaches "Ready" without invoking podman
- **AND** `Get-Process podman` finds no process

#### Scenario: trait dispatch is platform-driven

- **WHEN** `default_runtime()` is called on Linux
- **THEN** it returns a `PodmanRuntime` instance
- **AND** `runtime.name() == "podman"`

- **WHEN** `default_runtime()` is called on Windows
- **THEN** it returns a `WslRuntime` instance
- **AND** `runtime.name() == "wsl"`

### Requirement: WSL distros are the unit of execution on Windows

Each enclave service (proxy, forge, git, inference, router) on Windows SHALL be installed as a separate WSL2 distribution under `%LOCALAPPDATA%\Tillandsias\WSL\<service>`. The `Runtime::service_create` operation on Windows SHALL `wsl --import` the corresponding tarball; `service_remove` SHALL `wsl --unregister`. Distros MAY be cloned per-attach to provide `--rm` semantics; the clone SHALL be unregistered on detach.

#### Scenario: import succeeds for every enclave image

- **WHEN** `tillandsias --init` runs on Windows
- **THEN** for each of `{proxy, forge, git, inference, router}`, a corresponding WSL distro is imported and visible in `wsl --list --verbose`

#### Scenario: clone-on-attach ephemerality

- **WHEN** the user clicks "Attach Here" on a project
- **THEN** a new WSL distro `tillandsias-forge-<session_id>` is created from the forge image
- **AND** when the session ends, that clone is `wsl --unregister`-ed and its VHDX directory is removed
