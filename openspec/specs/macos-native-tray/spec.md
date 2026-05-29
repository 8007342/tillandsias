<!-- @trace spec:macos-native-tray -->
# macos-native-tray Specification

## Status

active
phase: 5

## Purpose

Define the contract for the macOS-native tray binary `tillandsias-macos-tray`
(produces `tillandsias-tray.app`). The binary runs on the host as an OS-native
AppKit application, owns an `NSStatusItem` (system menu bar icon) constructed
via `objc2-app-kit`, and delegates portable logic to
`tillandsias-host-shell`. The binary is responsible for driving the macOS
Virtualization.framework guest lifecycle through `objc2-virtualization` (via
the `VzRuntime` impl in `tillandsias-vm-layer`) and for routing terminal
attach actions through Terminal.app or iTerm2 (whichever the user has
installed and the system reports as default).

GUI passthrough (in-VM Chromium displayed on the macOS host) is **explicitly
deferred to v2**. In v1, this binary surfaces terminal-only workflows.

This spec is part of the Windows + macOS host-shell design wave. See plan:
`/home/tlatoani/.claude/plans/stateless-riding-newt.md`.

Cross-references:
- `host-shell-architecture` — portable contract this binary consumes.
- `vm-idiomatic-layer` — `VzRuntime` impl this binary drives.
- `vsock-transport` — wire to the in-VM headless.
- `vm-provisioning-lifecycle` — first-run rootfs/binary install.

## Requirements

### Requirement: AppKit `NSStatusItem` is the only tray surface
- **ID**: macos-native-tray.ui.nsstatusitem-only@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [macos-native-tray.invariant.no-tauri-or-webview, macos-native-tray.invariant.lsuielement-true]

The macOS tray binary SHALL render exclusively via `NSStatusItem` constructed
on the `NSStatusBar.systemStatusBar`. The bundle's `Info.plist` SHALL set
`LSUIElement = true` so the binary does not appear in the Dock or the
application switcher. The binary SHALL NOT embed a webview (no Tauri, no Wry,
no `WKWebView`). The status item SHALL be the sole user input surface.

@trace spec:macos-native-tray

#### Scenario: Status item appears in menu bar
- **WHEN** `tillandsias-tray.app` launches on a macOS 14+ host
- **THEN** the process SHALL call `[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength]`
- **AND** the user SHALL see the tillandsias icon in the menu bar within 500ms

#### Scenario: No Dock entry is created
- **WHEN** the binary is running
- **THEN** the macOS Dock SHALL NOT contain a tillandsias icon
- **AND** Cmd-Tab SHALL NOT list "tillandsias-tray" as a switchable app
- **AND** `Info.plist` SHALL contain `<key>LSUIElement</key><true/>`

#### Scenario: No webview is loaded
- **WHEN** the running tray process is inspected with `vmmap <pid>` or `otool -L`
- **THEN** the loaded library list SHALL NOT contain `WebKit.framework`, `WKWebView` symbols, or any Tauri runtime dylib

### Requirement: Menu items match the host-shell parity contract
- **ID**: macos-native-tray.ui.menu-parity@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [macos-native-tray.invariant.menu-from-host-shell-state, macos-native-tray.invariant.menu-renders-in-50ms, macos-native-tray.invariant.gui-items-deferred-to-v2]

The dropdown menu attached to the status item SHALL be built from a
`MenuStructure` snapshot returned by `tillandsias-host-shell`. Top-level
groups SHALL match the Linux tray contract: `status_text`, `projects`,
`agents`, `observatorium`, `opencode_web`, `github_login`. On macOS v1, the
`observatorium` and `opencode_web` items SHALL be rendered but disabled with
the reason "v2 — terminal-only in v1".

@trace spec:macos-native-tray, spec:host-shell-architecture

#### Scenario: Menu mirrors the shell snapshot
- **WHEN** the host shell publishes a `MenuStructure` with 3 projects
- **THEN** the menu SHALL contain exactly 3 project sub-items in the order published
- **AND** the menu SHALL be built within 50ms of the click event

#### Scenario: Observatorium and OpenCode Web are disabled with v2 marker
- **WHEN** the menu is built on macOS v1
- **THEN** the items "Observatorium" and "OpenCode Web" SHALL be present but `isEnabled = NO`
- **AND** the tooltip for both SHALL read "v2 — terminal-only in v1"
- **AND** clicking them SHALL be a no-op

#### Scenario: Quit triggers shell shutdown sequence
- **WHEN** the user clicks "Quit Tillandsias"
- **THEN** the binary SHALL call `host_shell::request_shutdown()` first
- **AND** SHALL call `[NSApp terminate:nil]` only after the shell reports `ShutdownComplete` (or after a 30s wall)

### Requirement: Virtualization.framework guest lifecycle is owned by this binary
- **ID**: macos-native-tray.lifecycle.vz-guest@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [macos-native-tray.invariant.vz-via-vm-layer, macos-native-tray.invariant.vz-cid-allocated-at-config]

The binary SHALL drive the macOS Virtualization.framework guest through the
`VzRuntime` impl in `tillandsias-vm-layer` (see `vm-idiomatic-layer`). The
guest's vsock CID SHALL be allocated at `VZVirtioSocketDeviceConfiguration`
time and pinned for the lifetime of the guest. The binary SHALL NOT touch
`objc2-virtualization` types directly — all VZ API calls go through the
layer.

@trace spec:macos-native-tray, spec:vm-idiomatic-layer

#### Scenario: VZ guest boots on first run
- **WHEN** the binary starts on a macOS 14+ host with no existing
  tillandsias VZ image
- **THEN** the binary SHALL call `VmRuntime::provision(VzOpts {
  kernel_path, initrd_path, rootfs_image, cid })`
- **AND** the layer SHALL construct a `VZVirtualMachineConfiguration` with a
  `VZVirtioSocketDeviceConfiguration` allocated CID
- **AND** the guest SHALL reach "ready" (vsock handshake) within 90s

#### Scenario: VZ guest restarts on subsequent runs
- **WHEN** the binary starts on a host where the rootfs image already exists
- **THEN** the binary SHALL call `VmRuntime::start()` (no re-provision)
- **AND** the existing rootfs SHALL be reattached to a fresh VM configuration

#### Scenario: All VZ API calls route through the vm layer
- **WHEN** `crates/tillandsias-macos-tray/src/**.rs` is searched for
  `objc2_virtualization::` or `VZVirtualMachine`
- **THEN** the only matches SHALL be inside `crates/tillandsias-vm-layer/src/vz.rs`
- **AND** the tray crate itself SHALL contain zero such matches

### Requirement: Terminal attach routes through Terminal.app or iTerm2 via `vm-exec`
- **ID**: macos-native-tray.lifecycle.terminal-attach@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [macos-native-tray.invariant.terminal-attach-no-ssh, macos-native-tray.invariant.terminal-uses-iterm2-when-default]

When the user clicks "Attach Here" on a project, the binary SHALL invoke
`vm-exec` (see `vm-idiomatic-layer`) to spawn `podman exec -it
tillandsias-<project>-forge bash` inside the VM, with the host-side terminal
hosted by iTerm2 when it is the user's default terminal (detected via
`defaults read com.apple.LaunchServices LSHandlers` or `osascript -e 'get
default application of (info for ((path to me) as alias))'`) and by
Terminal.app otherwise. The implementation SHALL NOT use SSH.

@trace spec:macos-native-tray, spec:vm-idiomatic-layer

#### Scenario: iTerm2 is preferred when set as default
- **WHEN** iTerm2 is the user's default terminal handler and the user clicks "Attach Here"
- **THEN** the binary SHALL use AppleScript to ask iTerm2 to open a new tab
  running `/usr/local/bin/vm-exec podman exec -it
  tillandsias-<project>-forge bash`
- **AND** the user SHALL see an iTerm2 tab with an interactive forge shell

#### Scenario: Terminal.app fallback when iTerm2 is not default
- **WHEN** iTerm2 is not present or is not the default
- **THEN** the binary SHALL invoke `open -a Terminal.app
  /tmp/tillandsias-vm-exec-launcher.sh` after writing a launcher script
- **AND** the user SHALL see a Terminal.app window with the same shell

#### Scenario: SSH is never invoked
- **WHEN** `crates/tillandsias-macos-tray/src/**.rs` and
  `crates/tillandsias-vm-layer/src/vz.rs` are searched for
  `Command::new("ssh")`
- **THEN** zero matches SHALL be found

### Requirement: GUI passthrough is explicitly deferred to v2
- **ID**: macos-native-tray.ui.gui-passthrough-v2@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [macos-native-tray.invariant.no-display-passthrough-in-v1]

The v1 binary SHALL NOT implement display passthrough for in-VM Chromium.
Prior research (the user's M5 Apple Silicon investigation) suggests it is
feasible, but is scheduled for a separate spec/change. The v1 binary SHALL
ship with `observatorium` and `opencode_web` menu items disabled and tagged
`v2 — terminal-only in v1`.

@trace spec:macos-native-tray

#### Scenario: v1 binary does not link to display frameworks
- **WHEN** the v1 binary is inspected with `otool -L`
- **THEN** it SHALL NOT link `Metal.framework` or `OpenGL.framework` or `IOSurface.framework`
- **AND** it SHALL NOT contain any code path that asks the VZ guest for a display surface

#### Scenario: v2 forward pointer is documented
- **WHEN** a developer reads the spec
- **THEN** the spec SHALL reference the (future) `macos-gui-passthrough` spec
  as the authoritative location for v2 work
- **AND** the cheatsheet `cheatsheets/runtime/macos-vz-gui-research-v2.md`
  SHALL document the M5 research findings

### Requirement: `--diagnose` CLI mode emits a stable bundled health report
- **ID**: macos-native-tray.diagnose.cli-health-report@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [macos-native-tray.invariant.diagnose-exit-codes]

@trace spec:macos-native-tray

The `tillandsias-tray` binary MUST support a `--diagnose` flag (and a
`--diagnose --json` variant) that prints a bundled health report and exits
without launching AppKit. The output MUST be stable across the v0.0.1
series so support tooling (`scripts/tray-diagnose.sh`,
`scripts/install-macos.sh` post-install verify) can rely on the shape.

#### Scenario: Human-readable report is emitted on `--diagnose`
- **GIVEN** the tray binary is invoked from a terminal with `--diagnose` (and
  no `--json`)
- **WHEN** the binary runs
- **THEN** stdout SHALL contain a section-per-field health report
  (Version, Bundle, Image-root, Release, Manifest pin, Control wire
  disclaimer, Status)
- **AND** the binary SHALL exit before invoking `NSApplication::run`
- **AND** the binary SHALL exit 0 if the image-root is fully provisioned, 2
  if degraded (any required artifact missing), or 1 on hard failure

#### Scenario: JSON output emits a schema-pinned object
- **GIVEN** `--diagnose --json`
- **WHEN** the binary runs
- **THEN** stdout SHALL be a parseable JSON object with the documented keys
  (`version`, `in_app`, `exe_path`, `image_root`, `rootfs_present`,
  `rootfs_bytes`, `kernel_present`, `kernel_bytes`, `initrd_present`,
  `initrd_bytes`, `release_tag`, `manifest_pin_aarch64_img`, `provisioned`)
- **AND** missing-artifact `*_bytes` fields SHALL serialise as JSON `null`
  (not absent and not `0`)
- **AND** the `provisioned` boolean SHALL be `true` iff rootfs +
  vmlinuz + initramfs.img all exist on disk
- **AND** the JSON schema SHALL be pinned by unit tests in
  `tillandsias-macos-tray::diagnose::tests`

#### Scenario: macOS-specific wire limitation is surfaced
- **GIVEN** `--diagnose` is invoked from a terminal (i.e. a separate process
  from any running tray)
- **WHEN** the report's control-wire section renders
- **THEN** the human format SHALL explicitly disclaim that live
  VM-phase + podman_ready are reachable only from the running tray
  process itself (per-VM-handle vsock; no `AF_VSOCK` on macOS)
- **AND** the JSON format SHALL omit a `wire` object entirely (no
  field that would lie about a probe the macOS path cannot perform)

## Invariants

### Invariant: No Tauri or WebView surface
- **ID**: macos-native-tray.invariant.no-tauri-or-webview
- **Expression**: `crates/tillandsias-macos-tray/Cargo.toml CONTAINS no [tauri, wry, webview]`
- **Measurable**: true

### Invariant: LSUIElement is true in Info.plist
- **ID**: macos-native-tray.invariant.lsuielement-true
- **Expression**: `Info.plist CONTAINS <key>LSUIElement</key><true/>`
- **Measurable**: true

### Invariant: Menu sourced from host shell state
- **ID**: macos-native-tray.invariant.menu-from-host-shell-state
- **Expression**: `menu_build_fn USES host_shell::MenuStructure AS sole_input`
- **Measurable**: true

### Invariant: Menu renders within 50ms
- **ID**: macos-native-tray.invariant.menu-renders-in-50ms
- **Expression**: `time(click_event → menu_visible) <= 50ms p99`
- **Measurable**: true

### Invariant: GUI items deferred to v2 on macOS
- **ID**: macos-native-tray.invariant.gui-items-deferred-to-v2
- **Expression**: `menu.observatorium.disabled = true AND menu.opencode_web.disabled = true ON macos_v1`
- **Measurable**: true

### Invariant: VZ operations route through vm layer
- **ID**: macos-native-tray.invariant.vz-via-vm-layer
- **Expression**: `crates/tillandsias-macos-tray/src/**.rs CONTAINS no objc2_virtualization::`
- **Measurable**: true

### Invariant: VZ CID allocated at config time
- **ID**: macos-native-tray.invariant.vz-cid-allocated-at-config
- **Expression**: `VZVirtioSocketDeviceConfiguration.cid IS_SET BEFORE machine.start()`
- **Measurable**: true

### Invariant: Terminal attach never uses SSH
- **ID**: macos-native-tray.invariant.terminal-attach-no-ssh
- **Expression**: `attach_here_handler CONTAINS no ssh`
- **Measurable**: true

### Invariant: Terminal uses iTerm2 when it is the default
- **ID**: macos-native-tray.invariant.terminal-uses-iterm2-when-default
- **Expression**: `iterm2_is_default => spawn_terminal_uses(iTerm2)`
- **Measurable**: true

### Invariant: `WIRE_UNREACHABLE_CHIP_TEXT` is pinned across trays
- **ID**: macos-native-tray.invariant.wire-unreachable-chip-text
- **Modality**: MUST
- **Measurable**: true via the unit test
  `wire_unreachable_chip_text_pinned` in
  `crates/tillandsias-macos-tray/src/action_host.rs`.

The live-status chip rendered when `spawn_vm_status_poller`'s Err branch
fires (mid-session wire failure — headless crash, VM externally terminated,
keepalive lost) SHALL be byte-identical to the windows tray's
`WIRE_UNREACHABLE_CHIP_TEXT` (windows commit `145ff3d2`):
`"\u{1F534} Wire unreachable"` (21 bytes UTF-8, leading codepoint
U+1F534 LARGE RED CIRCLE). Operators on either OS SHALL see the same
text for the same failure class.

### Invariant: `--diagnose` exit codes are limited to {0, 2, 1}
- **ID**: macos-native-tray.invariant.diagnose-exit-codes
- **Expression**: `crates/tillandsias-macos-tray/src/diagnose.rs::exit_code_from
  RETURNS one of {0, 2, 1}`
- **Measurable**: true via the unit test
  `exit_code_provisioned_zero_degraded_two`

  Tooling consumers (`scripts/tray-diagnose.sh`, `scripts/install-macos.sh`
  post-install verify, future support dashboards) branch on these exit codes.
  Adding new values would silently break consumers.

### Invariant: No display passthrough in v1
- **ID**: macos-native-tray.invariant.no-display-passthrough-in-v1
- **Expression**: `otool -L tillandsias-tray.app/Contents/MacOS/tillandsias-tray DOES_NOT_CONTAIN Metal.framework`
- **Measurable**: true

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:macos-tray-menu-renders` — primary verification of the parity contract.
- `litmus:cross-platform-terminal-attach` — verifies the terminal attach flow on macOS.
- `litmus:vsock-handshake` — transitively verifies vsock client lifecycle.

## Litmus Chain

Smallest actionable boundary: `cargo check -p tillandsias-macos-tray
--target aarch64-apple-darwin` then `cargo test -p tillandsias-macos-tray
--target aarch64-apple-darwin --filter status_item::tests`. Runtime entry
boundary: launching `tillandsias-tray.app` on a macOS 14+ runner and asserting
`NSStatusItem` is in the system status bar via an Accessibility API probe.

## Sources of Truth

- `cheatsheets/runtime/vz-framework-provisioning.md` — Virtualization.framework mechanics.
- `cheatsheets/runtime/macos-vz-gui-research-v2.md` — deferred v2 GUI passthrough notes.
- `cheatsheets/runtime/idiomatic-vm-exec.md` — vz exec discipline.
- Plan: `/home/tlatoani/.claude/plans/stateless-riding-newt.md`.

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:macos-native-tray" crates/ --include="*.rs"
```
