<!-- @trace spec:host-shell-architecture -->
# host-shell-architecture Specification

## Status

proposed
phase: 1

## Purpose

Define the contract for the shared host-side library `tillandsias-host-shell`
that backs both the Windows (Win32 NotifyIcon) and macOS (AppKit NSStatusItem)
native tray binaries. The host shell owns the portable, OS-agnostic
responsibilities that previously lived inside `tillandsias-headless`'s Linux
tray module: project discovery, menu state modelling, control-wire client
lifecycle, and VM orchestration delegation.

This spec is part of the Windows + macOS host-shell design wave. See plan:
`/home/tlatoani/.claude/plans/stateless-riding-newt.md`. The plan establishes
that on non-Linux hosts the tray runs as a thin native binary on the host while
the existing `tillandsias-headless` process runs inside a Fedora 44 Core VM
(WSL2 distro on Windows, Virtualization.framework guest on macOS). The host
shell mediates between the OS-native tray surface and the in-VM headless via
the vsock transport.

Cross-references:
- `windows-native-tray` — Win32 NotifyIcon implementation that consumes this shell.
- `macos-native-tray` — AppKit NSStatusItem implementation that consumes this shell.
- `vsock-transport` — the wire the shell uses to reach the in-VM headless.
- `vm-idiomatic-layer` — the abstraction the shell calls to provision/start/stop the VM.
- `vm-provisioning-lifecycle` — first-run and steady-state provisioning UX.
- `tillandsias-vault` — credential surface the shell does NOT see directly; tokens stay in-VM.

## Requirements

### Requirement: Host filesystem scanner enumerates `~/src/` projects
- **ID**: host-shell-architecture.scanner.local-project-discovery@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [host-shell-architecture.invariant.scanner-runs-on-host, host-shell-architecture.invariant.scanner-event-driven]

The host shell SHALL operate an event-driven filesystem watcher rooted at the
user's project home (`~/src/` on Linux/macOS, `%USERPROFILE%\src\` on Windows)
that emits structured `LocalProjectEvent` records every time a directory is
created, removed, or renamed at depth 1. The scanner SHALL run on the host
process (never inside the VM) because the host owns the user's source tree and
the VM only sees a virtio-fs / WSL `\\wsl$` projection of it.

@trace spec:host-shell-architecture

#### Scenario: Project home is enumerated on startup
- **WHEN** the host shell starts on a host with `~/src/foo`, `~/src/bar` present
- **THEN** the scanner SHALL emit two `LocalProjectEvent::Discovered` events
- **AND** the menu state model SHALL contain entries for both projects within 2s

#### Scenario: New project directory is detected without polling
- **WHEN** a user runs `git clone <repo> ~/src/baz` while the tray is running
- **THEN** the scanner SHALL emit `LocalProjectEvent::Discovered { name: "baz" }`
  via the `notify`-equivalent watcher within 1s
- **AND** the menu state model SHALL include the new project at the next paint

#### Scenario: Removed project directory is purged
- **WHEN** a user runs `rm -rf ~/src/foo`
- **THEN** the scanner SHALL emit `LocalProjectEvent::Removed { name: "foo" }`
- **AND** the menu state model SHALL drop the entry before the next paint

#### Scenario: Project home does not exist on first launch
- **WHEN** the host shell starts on a host where `~/src/` does not exist
- **THEN** the scanner SHALL create the directory and continue, emitting zero events
- **AND** the menu SHALL show "No projects yet — create one in ~/src/"

### Requirement: Portable `MenuStructure` is the single source of truth for menu paint
- **ID**: host-shell-architecture.menu.portable-state-model@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [host-shell-architecture.invariant.menu-state-toolkit-agnostic, host-shell-architecture.invariant.menu-parity-with-linux]

The host shell SHALL expose a `MenuStructure` type that is the portable analog
of the Linux `TrayUiState`. Both the Win32 NotifyIcon backend and the AppKit
NSStatusItem backend SHALL paint exclusively from this structure. The
structure SHALL be free of any OS-specific types (no `HMENU`, no `NSMenu`,
no D-Bus IDs). The structure SHALL include the same logical sections as the
Linux tray: project list, agent launch entries (claude/codex/opencode),
observatorium link, opencode-web link, GitHub login state, and overall status
text.

@trace spec:host-shell-architecture

#### Scenario: Menu structure includes the full parity contract
- **WHEN** the host shell builds a `MenuStructure` with one ready project and a logged-in GitHub identity
- **THEN** the structure SHALL contain exactly these top-level groups: `status_text`, `projects`, `agents`, `observatorium`, `opencode_web`, `github_login`
- **AND** the `agents` group SHALL list `claude`, `codex`, `opencode` as launchable items

#### Scenario: Toolkit-agnostic snapshot is paintable on either OS
- **WHEN** the same `MenuStructure` snapshot is fed to the Windows backend and the macOS backend
- **THEN** both backends SHALL render the same logical menu items in the same order
- **AND** neither backend SHALL need to inspect the structure with OS-specific casts

#### Scenario: Disabled items carry a v2-deferred marker
- **WHEN** the structure is built on macOS and an item is gated by GUI passthrough
- **THEN** the entry SHALL have `disabled: true` and `disabled_reason: "v2 — terminal-only in v1"`
- **AND** the macOS backend SHALL render the item greyed out with the reason as the tooltip

### Requirement: vsock client lifecycle is owned by the host shell
- **ID**: host-shell-architecture.transport.vsock-client-lifecycle@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [host-shell-architecture.invariant.vsock-reconnect-with-backoff, host-shell-architecture.invariant.vsock-status-surfaces-in-menu]

The host shell SHALL own the lifetime of the vsock connection to the in-VM
headless via `tillandsias-control-wire`. The shell SHALL surface the
connection state in the `MenuStructure.status_text` field so the user always
knows whether the host can reach the VM. On disconnect, the shell SHALL
reconnect with exponential backoff (250ms, 500ms, 1s, 2s, 4s, capped at 4s)
and SHALL NOT poll synchronously.

@trace spec:host-shell-architecture

#### Scenario: Initial handshake succeeds
- **WHEN** the VM is up and listening on `vsock:<vm-cid>:42420`
- **THEN** the shell SHALL exchange `Hello`/`HelloAck` within 2s of VM start
- **AND** `status_text` SHALL transition from `🔵 Starting…` to `Ready`

#### Scenario: Transient disconnect triggers backoff reconnect
- **WHEN** the in-VM headless restarts and the vsock connection drops
- **THEN** the shell SHALL surface `🔵 Reconnecting…` in `status_text`
- **AND** the shell SHALL attempt reconnects on the 250ms/500ms/1s/2s/4s schedule
- **AND** the menu SHALL flip back to `Ready` on the first successful handshake

#### Scenario: Reconnect attempts are event-driven, never polled
- **WHEN** the shell is in the `Reconnecting` state
- **THEN** the shell SHALL NOT busy-loop; the backoff SHALL be implemented via `tokio::time::sleep`
- **AND** CPU usage of the host process SHALL remain below 0.5% during the wait

### Requirement: VM orchestration is delegated to `tillandsias-vm-layer`
- **ID**: host-shell-architecture.lifecycle.vm-orchestration-delegation@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [host-shell-architecture.invariant.no-direct-vm-shellouts, host-shell-architecture.invariant.lifecycle-events-traced]

The host shell SHALL NOT shell out to `wsl.exe`, `vmrun`, the
Virtualization.framework C API, or any OS-specific VM tool directly. All VM
lifecycle operations (`provision`, `start`, `stop`, `wait_ready`, `exec`)
SHALL go through the `VmRuntime` trait exported by `tillandsias-vm-layer`.
This mirrors the existing `tillandsias-podman` discipline established in
`crates/tillandsias-podman/`.

@trace spec:host-shell-architecture, spec:vm-idiomatic-layer

#### Scenario: Provision call routes through the trait
- **WHEN** the host shell needs to provision the VM on first run
- **THEN** the shell SHALL call `VmRuntime::provision(&self, opts)` on the active backend
- **AND** the shell crate's source SHALL contain zero references to `Command::new("wsl")`, `Command::new("vmrun")`, or `vz_*` C symbols

#### Scenario: Cloud project refresh delegates to the VM
- **WHEN** the menu surfaces a "Refresh GitHub repo list" action
- **THEN** the shell SHALL send `ControlMessage::CloudRefreshRequest` over vsock to the in-VM headless
- **AND** the in-VM git container SHALL perform the `gh` call (the GitHub token never leaves the VM)
- **AND** the shell SHALL paint the reply (`CloudRefreshReply`) into the menu

#### Scenario: Tray exit triggers graceful drain
- **WHEN** the user quits the tray
- **THEN** the shell SHALL emit `ControlMessage::VmShutdownRequest { drain_timeout_ms: 10000 }` via vsock
- **AND** wait up to 30s for the VM to report stopped
- **AND** invoke `VmRuntime::stop(force=true)` only after the 30s wall

### Requirement: Host shell never holds long-lived credentials
- **ID**: host-shell-architecture.security.no-host-credentials@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [host-shell-architecture.invariant.no-tokens-in-host-process, host-shell-architecture.invariant.installation-uuid-is-the-only-host-secret]

The host shell process SHALL NOT load, cache, or transmit GitHub tokens,
ollama API keys, or any other long-lived credential. The only host-side
secret the shell SHALL be aware of is the `tillandsias-installation-uuid`
stored in Windows Credential Manager / macOS Keychain (see
`tillandsias-vault`), which the shell pushes into the VM on boot for vault
auto-unseal derivation. All other secrets are reachable only by in-VM
containers via the vault client.

@trace spec:host-shell-architecture, spec:tillandsias-vault

#### Scenario: Process memory contains no GitHub tokens
- **WHEN** the host shell process is inspected with a memory dump tool after handling a `CloudRefreshRequest`
- **THEN** the dump SHALL NOT contain any string matching the GitHub PAT pattern (`ghp_[A-Za-z0-9]{36}` / `gho_…`)
- **AND** the only OS keychain entry the process SHALL have read is `tillandsias-vm-uuid`

#### Scenario: Installation-uuid is generated on first provision
- **WHEN** the host shell provisions the VM for the first time on a fresh host
- **THEN** the shell SHALL generate a UUIDv4 and write it to the OS keychain entry `tillandsias-vm-uuid`
- **AND** subsequent provisioning runs SHALL read the existing UUID rather than generating a new one

## Invariants

### Invariant: Scanner runs on host, not in VM
- **ID**: host-shell-architecture.invariant.scanner-runs-on-host
- **Expression**: `host_shell.scanner.root IS_ON host_filesystem AND NEVER routed_through_vsock`
- **Measurable**: true

### Invariant: Scanner is event-driven
- **ID**: host-shell-architecture.invariant.scanner-event-driven
- **Expression**: `scanner_implementation USES notify_crate_or_OS_equivalent AND NEVER fs_polling_loop`
- **Measurable**: true

### Invariant: Menu state is toolkit-agnostic
- **ID**: host-shell-architecture.invariant.menu-state-toolkit-agnostic
- **Expression**: `MenuStructure CONTAINS no HMENU OR NSMenu OR DBus_path types`
- **Measurable**: true

### Invariant: Menu parity with Linux tray
- **ID**: host-shell-architecture.invariant.menu-parity-with-linux
- **Expression**: `MenuStructure.top_groups EQUALS linux_tray.top_groups`
- **Measurable**: true

### Invariant: vsock client reconnects with backoff
- **ID**: host-shell-architecture.invariant.vsock-reconnect-with-backoff
- **Expression**: `disconnect EVENT => reconnect_schedule IS [250ms, 500ms, 1s, 2s, 4s, 4s, …]`
- **Measurable**: true

### Invariant: vsock status surfaces in menu
- **ID**: host-shell-architecture.invariant.vsock-status-surfaces-in-menu
- **Expression**: `MenuStructure.status_text REFLECTS vsock_client.state`
- **Measurable**: true

### Invariant: No direct VM shellouts from the shell
- **ID**: host-shell-architecture.invariant.no-direct-vm-shellouts
- **Expression**: `crates/tillandsias-host-shell/src/**.rs CONTAINS no Command::new("wsl") OR vmrun OR vz_* C symbols`
- **Measurable**: true

### Invariant: Lifecycle events are traced
- **ID**: host-shell-architecture.invariant.lifecycle-events-traced
- **Expression**: `provision|start|stop|shutdown_request EMITS log_event WITH spec="host-shell-architecture"`
- **Measurable**: true

### Invariant: No tokens in the host process
- **ID**: host-shell-architecture.invariant.no-tokens-in-host-process
- **Expression**: `host_process_memory MATCHES NONE OF [ghp_, gho_, ghs_, sk_live_, AKIA]`
- **Measurable**: true

### Invariant: Installation-uuid is the only host secret
- **ID**: host-shell-architecture.invariant.installation-uuid-is-the-only-host-secret
- **Expression**: `os_keychain_reads_by_host_shell SUBSET_OF {tillandsias-vm-uuid}`
- **Measurable**: true

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:windows-tray-menu-renders` — exercises the menu parity contract on Windows.
- `litmus:macos-tray-menu-renders` — exercises the menu parity contract on macOS.
- `litmus:vsock-handshake` — exercises the shell's vsock client lifecycle (transitively).

## Litmus Chain

Smallest actionable boundary: `cargo build -p tillandsias-host-shell --lib` followed by
`cargo test -p tillandsias-host-shell --lib menu_structure::tests` with
`--filter host-shell-architecture --strict`. Runtime entry boundary: spawning
`tillandsias-windows-tray` or `tillandsias-macos-tray` against a stub VM
runtime and asserting `MenuStructure` paint parity.

## Sources of Truth

- `cheatsheets/runtime/vsock-transport.md` — vsock CID/port semantics consumed by the shell.
- `cheatsheets/runtime/idiomatic-vm-exec.md` — discipline the shell enforces.
- Plan: `/home/tlatoani/.claude/plans/stateless-riding-newt.md` — design decisions.

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:host-shell-architecture" crates/ --include="*.rs"
```
