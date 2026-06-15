<!-- @trace spec:windows-native-tray -->
# windows-native-tray Specification

## Status

active
phase: 4

## Purpose

Define the contract for the Windows-native tray binary
`tillandsias-windows-tray` (produces `tillandsias-tray.exe`). The binary runs
on the host as an OS-native Win32 application, registers a NotifyIcon (system
tray icon) via the `Shell_NotifyIcon` API surface (wrapped by the `tray-icon`
crate, with raw `windows-rs` fallbacks for parity with the Linux tray), and
delegates all logic to `tillandsias-host-shell`. The tray is responsible for
the WSL2 distro lifecycle of the Fedora 44 Core VM and for routing terminal
attach actions through Windows Terminal via the `vm-exec` abstraction.

This spec is part of the Windows + macOS host-shell design wave. See plan:
`/home/tlatoani/.claude/plans/stateless-riding-newt.md`. The user decision
(matrix row 6) is that the binary is intentionally thin — all portable logic
lives in `tillandsias-host-shell` so the macOS sibling can reuse it.

Cross-references:
- `host-shell-architecture` — portable contract this binary consumes.
- `vm-idiomatic-layer` — `WslRuntime` impl this binary drives.
- `vsock-transport` — wire to the in-VM headless.
- `vm-provisioning-lifecycle` — first-run rootfs/binary install.

## Requirements

### Requirement: Win32 NotifyIcon is the only tray surface
- **ID**: windows-native-tray.ui.notify-icon-only@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [windows-native-tray.invariant.no-tauri-or-webview, windows-native-tray.invariant.notify-icon-registered-on-explorer-restart]

The Windows tray binary SHALL render exclusively via the Win32 `NotifyIcon` /
`Shell_NotifyIcon` API. It SHALL NOT embed a webview (no Tauri, no Wry, no
WebView2). The icon SHALL be registered on startup and re-registered when
Explorer restarts (signalled by the `WM_TASKBARCREATED` broadcast message).
The icon click and right-click menu SHALL be the sole user input surface;
there is no window.

@trace spec:windows-native-tray

#### Scenario: Icon registers on first launch
- **WHEN** `tillandsias-tray.exe` starts on a Windows 11 desktop session
- **THEN** the process SHALL call `Shell_NotifyIconW(NIM_ADD, &nid)` with `uID = 1`
- **AND** the system tray SHALL show the tillandsias icon within 500ms

#### Scenario: Icon re-registers on Explorer restart
- **WHEN** the tray binary is running and `explorer.exe` is killed and restarted
- **THEN** the binary SHALL observe `WM_TASKBARCREATED` (registered via `RegisterWindowMessageW(L"TaskbarCreated")`)
- **AND** the binary SHALL re-issue `Shell_NotifyIconW(NIM_ADD, …)` to restore the icon

#### Scenario: No webview is loaded
- **WHEN** the running tray process is inspected with `tasklist /M`
- **THEN** the loaded module list SHALL NOT contain `WebView2Loader.dll`, `WebView2.dll`, or any Tauri runtime DLL

### Requirement: Menu items match the host-shell parity contract
- **ID**: windows-native-tray.ui.menu-parity@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [windows-native-tray.invariant.menu-from-host-shell-state, windows-native-tray.invariant.menu-renders-in-50ms]

The right-click context menu SHALL be built from a `MenuStructure` snapshot
returned by `tillandsias-host-shell` (see `host-shell-architecture`). The
binary SHALL NOT compose menu items independently of the shell. Top-level
groups SHALL match the Linux tray contract: `status_text`, `projects`,
`agents`, `observatorium`, `opencode_web`, `github_login`.

@trace spec:windows-native-tray, spec:host-shell-architecture

#### Scenario: Menu mirrors the shell snapshot
- **WHEN** the host shell publishes a `MenuStructure` with 2 projects and a logged-in GitHub identity
- **THEN** the menu SHALL contain exactly 2 project sub-items and a "GitHub: <user>" entry
- **AND** the menu SHALL be built within 50ms of the right-click event

#### Scenario: Disabled v2 items render as greyed out
- **WHEN** the snapshot marks an item `disabled: true, disabled_reason: "v2"`
- **THEN** the menu item SHALL be created with `MF_GRAYED` (or `tray-icon` equivalent)
- **AND** the tooltip SHALL display the disabled reason

#### Scenario: Quit triggers shell shutdown sequence
- **WHEN** the user clicks "Quit Tillandsias"
- **THEN** the binary SHALL call `host_shell::request_shutdown()` first
- **AND** SHALL exit the message loop only after the shell reports `ShutdownComplete` (or after a 30s wall)

### Requirement: WSL2 distro lifecycle is owned by this binary
- **ID**: windows-native-tray.lifecycle.wsl-distro-registration@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [windows-native-tray.invariant.wsl-via-vm-layer, windows-native-tray.invariant.distro-name-pinned]

The binary SHALL drive WSL2 distro provisioning and lifecycle through the
`WslRuntime` impl in `tillandsias-vm-layer` (see `vm-idiomatic-layer`). The
distro name SHALL be the constant `tillandsias`. Registration SHALL use `wsl
--import tillandsias <install-path> <rootfs.tar.xz>` (routed through the vm
layer). The binary SHALL NOT shell out to `wsl.exe` directly outside the vm
layer.

@trace spec:windows-native-tray, spec:vm-idiomatic-layer

#### Scenario: Distro registers on first run
- **WHEN** the binary starts on a host where `wsl --list --quiet` does NOT include `tillandsias`
- **THEN** the binary SHALL call `VmRuntime::provision(WslOpts { distro_name: "tillandsias", rootfs_path, install_path })`
- **AND** the call SHALL execute `wsl --import tillandsias <install-path> <rootfs.tar.xz>` via the layer
- **AND** the resulting distro SHALL appear in `wsl --list --quiet` within 60s

#### Scenario: Distro starts on subsequent runs
- **WHEN** the binary starts on a host where `wsl --list --quiet` already includes `tillandsias`
- **THEN** the binary SHALL call `VmRuntime::start()` (which runs `wsl -d tillandsias -- /usr/bin/tillandsias --headless --listen-vsock 42420`)
- **AND** SHALL NOT re-import the distro

#### Scenario: All wsl.exe invocations route through the vm layer
- **WHEN** `crates/tillandsias-windows-tray/src/**.rs` is searched for `Command::new("wsl")`
- **THEN** the only matches SHALL be inside `crates/tillandsias-vm-layer/src/wsl.rs`
- **AND** the tray crate itself SHALL contain zero such matches

### Requirement: WSLg passthrough enables in-VM Chromium on supported hosts
- **ID**: windows-native-tray.ui.wslg-chromium-passthrough@v1
- **Modality**: SHOULD
- **Measurable**: true
- **Invariants**: [windows-native-tray.invariant.wslg-detection-event-driven, windows-native-tray.invariant.opencode-web-disabled-without-wslg]

On Windows 11 hosts with WSLg available (Win11 + appropriate GPU driver), the
binary SHALL surface "Observatorium" and "OpenCode Web" as launchable menu
items that pipe an in-VM Chromium container's display through the WSLg X11 /
Wayland surface. On Windows 10 or Win11-without-WSLg hosts, those items SHALL
be disabled with the reason "Requires Windows 11 + WSLg".

@trace spec:windows-native-tray

#### Scenario: WSLg-capable host enables browser surface
- **WHEN** the binary detects Windows 11 and `wsl -d tillandsias -- pkg-config --exists wayland-client` returns 0
- **THEN** the menu SHALL render "Observatorium" and "OpenCode Web" as enabled launchable items
- **AND** clicking either item SHALL launch the in-VM Chromium container with `DISPLAY=:0` and `WAYLAND_DISPLAY=wayland-0`

#### Scenario: Non-WSLg host disables browser surface gracefully
- **WHEN** the host is Windows 10 OR WSLg is not present
- **THEN** the menu SHALL render both items with `MF_GRAYED`
- **AND** the tooltip SHALL read "Requires Windows 11 + WSLg"

### Requirement: Terminal attach routes through Windows Terminal via `vm-exec`
- **ID**: windows-native-tray.lifecycle.terminal-attach@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [windows-native-tray.invariant.terminal-attach-no-ssh, windows-native-tray.invariant.terminal-uses-wt-when-available]

When the user clicks "Attach Here" on a project, the binary SHALL invoke
`vm-exec` (see `vm-idiomatic-layer`) to spawn `podman exec -it
tillandsias-<project>-forge bash` inside the VM, with the host-side terminal
hosted by Windows Terminal (`wt.exe`) when it is installed and by `conhost`
otherwise. The implementation SHALL NOT use SSH.

@trace spec:windows-native-tray, spec:vm-idiomatic-layer

#### Scenario: Windows Terminal is preferred when present
- **WHEN** `wt.exe` is on PATH and the user clicks "Attach Here"
- **THEN** the binary SHALL spawn `wt.exe new-tab --title "tillandsias-<project>" wsl -d tillandsias -- /usr/local/bin/vm-exec podman exec -it tillandsias-<project>-forge bash`
- **AND** the user SHALL see a Windows Terminal tab with an interactive forge shell

#### Scenario: conhost fallback when wt.exe is missing
- **WHEN** `wt.exe` is not on PATH
- **THEN** the binary SHALL spawn `cmd.exe /c start "" wsl -d tillandsias -- /usr/local/bin/vm-exec podman exec -it tillandsias-<project>-forge bash`
- **AND** the user SHALL see a conhost window with the same shell

#### Scenario: SSH is never invoked
- **WHEN** `crates/tillandsias-windows-tray/src/**.rs` and `crates/tillandsias-vm-layer/src/wsl.rs` are searched for `Command::new("ssh")`
- **THEN** zero matches SHALL be found

### Requirement: `--diagnose` CLI mode emits a stable bundled health report
- **ID**: windows-native-tray.diagnose.cli-health-report@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [windows-native-tray.invariant.diagnose-exit-codes]

@trace spec:windows-native-tray

The `tillandsias-tray.exe` binary MUST support a `--diagnose` flag (and a
`--diagnose --json` variant) that prints a bundled health report and exits
without launching the Win32 message loop. The output MUST be stable across
the v0.0.1 series so support tooling (`scripts/tray-diagnose.ps1`,
`scripts/install-windows.ps1` post-install verify) can rely on the shape.

#### Scenario: Human-readable report is emitted on `--diagnose`
- **GIVEN** the tray binary is invoked from a console with `--diagnose` (and
  no `--json`)
- **WHEN** the binary runs
- **THEN** stdout SHALL contain a section-per-field health report
  (Version, Log file, Log exists, `wt.exe`, Distro registration, Release
  tag, Manifest pin, Control wire status, Last event, recent log tail)
- **AND** the binary SHALL exit before invoking `create_message_window`
- **AND** the binary SHALL exit 0 if `distro_registered` AND
  `wire.reachable` AND `wire.phase == "Ready"`; 2 if degraded (any check
  failed but the tool ran end-to-end); or 1 on a hard failure (tokio
  runtime build refused, etc.)

#### Scenario: JSON output emits a schema-pinned object
- **GIVEN** `--diagnose --json`
- **WHEN** the binary runs
- **THEN** stdout SHALL be a parseable JSON object with the documented top
  level keys (`version`, `log_path`, `log_exists`, `wt_present`, `distro`,
  `distro_registered`, `release_tag`, `manifest_pin_x86_64_oci_tar_xz`, `wire`,
  `recent_log_tail`)
- **AND** the `wire` nested object SHALL contain (`reachable`, `phase`,
  `podman_ready`, `last_event`, `error`)
- **AND** `manifest_pin_x86_64_oci_tar_xz` SHALL serialise as a JSON string when
  the embedded manifest has an `x86_64.oci.tar.xz` pin and as JSON `null` when it
  does not (a non-hex placeholder like `"pending-ci"` MUST serialise as
  `null`, not a garbage substring)
- **AND** `recent_log_tail` SHALL serialise as a JSON array (empty array
  when the log file does not yet exist, not `null` or absent)
- **AND** the JSON schema SHALL be pinned by unit tests in
  `tillandsias-windows-tray::notify_icon::tests`
  (`diagnose_json_top_level_keys_pinned`,
  `diagnose_json_wire_object_keys_pinned`,
  `diagnose_json_manifest_pin_some_serializes_as_string`,
  `diagnose_json_manifest_pin_none_serializes_as_null`,
  `diagnose_json_recent_log_tail_is_array`)

#### Scenario: Capturing `--diagnose --json` from PowerShell uses `cmd.exe` redirect
- **GIVEN** the installed (release / GUI-subsystem) tray binary is invoked
  from a PowerShell session and the caller needs to capture the JSON
- **WHEN** the caller uses `cmd /c "<exe> --diagnose --json > out.json 2>nul"`
- **THEN** `out.json` SHALL receive the complete machine-readable report
- **AND** PowerShell's direct stdout capture (`$x = & exe`, `& exe > file`)
  MAY silently drop large `println!` writes from GUI-subsystem binaries and
  thus is NOT a supported capture path (the cheatsheet documents this)

## Invariants

### Invariant: `--diagnose` exit codes are limited to {0, 2, 1}
- **ID**: windows-native-tray.invariant.diagnose-exit-codes
- **Modality**: MUST
- **Measurable**: true via the unit test
  `exit_code_provisioned_zero_degraded_two` in
  `crates/tillandsias-windows-tray/src/notify_icon.rs`.

The `--diagnose` and `--diagnose --json` modes SHALL exit with one of three
codes: **0** (fully healthy: distro registered AND wire reachable AND phase
Ready), **2** (degraded: the binary ran end-to-end but at least one check
failed), or **1** (hard failure: the tray could not run `--diagnose`
itself). Tooling MUST be able to use the exit code as a tri-state without
parsing stdout.

### Invariant: `WIRE_UNREACHABLE_CHIP_TEXT` is pinned across trays
- **ID**: windows-native-tray.invariant.wire-unreachable-chip-text
- **Modality**: MUST
- **Measurable**: true via the unit test
  `wire_unreachable_chip_text_pinned` in
  `crates/tillandsias-windows-tray/src/notify_icon.rs`.

The live-status chip rendered when `refresh_vm_status` cannot reach the
in-VM headless SHALL be byte-identical to the macOS tray's
`WIRE_UNREACHABLE_CHIP_TEXT` (slice 23, commit `cbeedb4a`):
`"\u{1F534} Wire unreachable"` (21 bytes UTF-8, leading codepoint
U+1F534 LARGE RED CIRCLE). Operators on either OS SHALL see the same
text for the same failure class.



### Invariant: No Tauri or WebView surface
- **ID**: windows-native-tray.invariant.no-tauri-or-webview
- **Expression**: `crates/tillandsias-windows-tray/Cargo.toml CONTAINS no [tauri, wry, webview2]`
- **Measurable**: true

### Invariant: NotifyIcon re-registers on Explorer restart
- **ID**: windows-native-tray.invariant.notify-icon-registered-on-explorer-restart
- **Expression**: `WM_TASKBARCREATED HANDLER CALLS Shell_NotifyIconW(NIM_ADD, …)`
- **Measurable**: true

### Invariant: Menu sourced from host shell state
- **ID**: windows-native-tray.invariant.menu-from-host-shell-state
- **Expression**: `menu_build_fn USES host_shell::MenuStructure AS sole_input`
- **Measurable**: true

### Invariant: Menu renders within 50ms
- **ID**: windows-native-tray.invariant.menu-renders-in-50ms
- **Expression**: `time(right_click_event → menu_visible) <= 50ms p99`
- **Measurable**: true

### Invariant: WSL operations route through vm layer
- **ID**: windows-native-tray.invariant.wsl-via-vm-layer
- **Expression**: `crates/tillandsias-windows-tray/src/**.rs CONTAINS no Command::new("wsl")`
- **Measurable**: true

### Invariant: Distro name is pinned to "tillandsias"
- **ID**: windows-native-tray.invariant.distro-name-pinned
- **Expression**: `distro_name CONST_EQ "tillandsias"`
- **Measurable**: true

### Invariant: WSLg detection is event-driven
- **ID**: windows-native-tray.invariant.wslg-detection-event-driven
- **Expression**: `wslg_available IS_COMPUTED_ONCE_AT_STARTUP AND cached`
- **Measurable**: true

### Invariant: OpenCode Web is disabled without WSLg
- **ID**: windows-native-tray.invariant.opencode-web-disabled-without-wslg
- **Expression**: `NOT wslg_available => menu.opencode_web.disabled = true`
- **Measurable**: true

### Invariant: Terminal attach never uses SSH
- **ID**: windows-native-tray.invariant.terminal-attach-no-ssh
- **Expression**: `attach_here_handler CONTAINS no ssh OR plink OR putty`
- **Measurable**: true

### Invariant: Terminal uses wt.exe when available
- **ID**: windows-native-tray.invariant.terminal-uses-wt-when-available
- **Expression**: `wt_on_path => spawn_terminal_uses(wt.exe)`
- **Measurable**: true

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:windows-tray-menu-renders` — primary verification of the parity contract.
- `litmus:cross-platform-terminal-attach` — verifies the terminal attach flow on Windows.
- `litmus:vsock-handshake` — transitively verifies vsock client lifecycle.

## Litmus Chain

Smallest actionable boundary: `cargo check -p tillandsias-windows-tray
--target x86_64-pc-windows-msvc` then `cargo test -p tillandsias-windows-tray
--target x86_64-pc-windows-msvc --filter notify_icon::tests`. Runtime entry
boundary: spawning `tillandsias-tray.exe` on a Windows 11 runner and asserting
the NotifyIcon is registered with `Shell_NotifyIcon_GetRect`.

## Sources of Truth

- `cheatsheets/runtime/wsl2-provisioning.md` — WSL2 mechanics.
- `cheatsheets/runtime/wslg-chromium-passthrough.md` — WSLg display passthrough.
- `cheatsheets/runtime/idiomatic-vm-exec.md` — wsl exec discipline.
- Plan: `/home/tlatoani/.claude/plans/stateless-riding-newt.md`.

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:windows-native-tray" crates/ --include="*.rs"
```
