<!-- @trace spec:vm-idiomatic-layer -->
# vm-idiomatic-layer Specification

## Status

active
phase: 2

## Purpose

Define the contract for the `tillandsias-vm-layer` crate: a single Rust API
that abstracts host↔VM operations behind a `VmRuntime` trait with two
backends. On Windows, the `WslRuntime` backend drives WSL2 distros via the
`wsl.exe` command-line and (where available) the `Win32_HCS_HostComputeSystem`
COM surface. On macOS, the `VzRuntime` backend drives Virtualization.framework
guests via `objc2-virtualization`. The crate enforces the same discipline the
existing `tillandsias-podman` crate enforces for podman: **no raw shell-outs to
`wsl.exe`, `vmrun`, or VZ API calls outside this crate**.

This spec is part of the Windows + macOS host-shell design wave. See plan:
`/home/tlatoani/.claude/plans/stateless-riding-newt.md`. The discipline analog
is `crates/tillandsias-podman/`, which is the only crate allowed to invoke the
`podman` binary directly. `tillandsias-vm-layer` plays the same role for VM
backends.

Cross-references:
- `host-shell-architecture` — sole consumer of this trait.
- `windows-native-tray`, `macos-native-tray` — depend on this trait transitively.
- `vm-provisioning-lifecycle` — UX layer on top of `VmRuntime::provision`.
- `vsock-transport` — uses CIDs allocated by this layer at VM construction time.

## Requirements

### Requirement: `VmRuntime` trait is the only public surface
- **ID**: vm-idiomatic-layer.api.vm-runtime-trait@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [vm-idiomatic-layer.invariant.trait-methods-fixed, vm-idiomatic-layer.invariant.trait-async-and-send]

The crate SHALL expose a single public trait `VmRuntime` with the following
async methods: `provision(&self, opts: ProvisionOpts) -> Result<()>`,
`start(&self) -> Result<()>`, `stop(&self, force: bool) -> Result<()>`,
`exec(&self, cmd: VmCommand) -> Result<ExitStatus>`, `wait_ready(&self,
timeout: Duration) -> Result<()>`. The trait SHALL be `Send + Sync`. All
other implementation details (process spawning, VZ machine config, CID
allocation, rootfs caching paths) SHALL be `pub(crate)` or private.

@trace spec:vm-idiomatic-layer

#### Scenario: Trait surface is closed
- **WHEN** the public API is enumerated via `cargo public-api`
- **THEN** the only public types SHALL be: `VmRuntime` trait, `ProvisionOpts`, `VmCommand`, `ExitStatus`, `VmError`, factory function `new_runtime() -> Box<dyn VmRuntime>`

#### Scenario: All methods are async and Send
- **WHEN** the trait definition is inspected
- **THEN** every method SHALL return `impl Future + Send`
- **AND** the trait SHALL be useable via `Arc<dyn VmRuntime>` in a tokio multi-threaded runtime

#### Scenario: Factory chooses backend based on cfg
- **WHEN** `new_runtime()` is called on Windows
- **THEN** it SHALL return a `WslRuntime` instance
- **WHEN** called on macOS
- **THEN** it SHALL return a `VzRuntime` instance
- **WHEN** called on Linux
- **THEN** it SHALL return a `LocalLinuxRuntime` fake (no-op provision; useful for Phase 2 integration tests)

### Requirement: `WslRuntime` is the only place `wsl.exe` is invoked
- **ID**: vm-idiomatic-layer.discipline.wsl-encapsulation@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [vm-idiomatic-layer.invariant.no-wsl-shellouts-outside-vm-layer]

The `WslRuntime` impl SHALL be the only location in the workspace where
`Command::new("wsl")` or any other process invocation of `wsl.exe` is
permitted. All other crates (including `tillandsias-windows-tray`) SHALL go
through the trait. This mirrors the discipline already enforced for podman by
`tillandsias-podman::PodmanClient`.

@trace spec:vm-idiomatic-layer

#### Scenario: Only the wsl module shells out
- **WHEN** the workspace is searched for `Command::new("wsl")` (excluding tests and `// allowed-bootstrap`-annotated lines)
- **THEN** the only matches SHALL be inside `crates/tillandsias-vm-layer/src/wsl.rs`

#### Scenario: Idiomatic helpers cover all common operations
- **WHEN** the `WslRuntime` is inspected
- **THEN** it SHALL expose private helpers for: `wsl_import`, `wsl_terminate`, `wsl_list`, `wsl_exec`
- **AND** none of these helpers SHALL build the wsl command line via raw string concatenation — `std::process::Command::args` SHALL be used

### Requirement: `VzRuntime` is the only place Virtualization.framework symbols are touched
- **ID**: vm-idiomatic-layer.discipline.vz-encapsulation@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [vm-idiomatic-layer.invariant.no-vz-symbols-outside-vm-layer]

The `VzRuntime` impl SHALL be the only location in the workspace that
imports `objc2_virtualization::*` or otherwise touches the VZ C API.
All other crates (including `tillandsias-macos-tray`) SHALL go through the
trait.

@trace spec:vm-idiomatic-layer

#### Scenario: Only the vz module imports objc2_virtualization
- **WHEN** the workspace is searched for `use objc2_virtualization` (excluding tests)
- **THEN** the only matches SHALL be inside `crates/tillandsias-vm-layer/src/vz.rs`

#### Scenario: VZ machine lifecycle is wrapped
- **WHEN** the VZ backend boots a guest
- **THEN** it SHALL construct a `VZVirtualMachineConfiguration` privately, call `validate`, and only expose `start`/`stop` via the trait
- **AND** no VZ types SHALL appear in the trait's public method signatures

### Requirement: `exec` propagates stdio and exit code with TTY support
- **ID**: vm-idiomatic-layer.api.exec-tty-passthrough@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [vm-idiomatic-layer.invariant.exec-stdio-mapped, vm-idiomatic-layer.invariant.exit-code-fidelity]

The `VmRuntime::exec` method SHALL propagate stdin, stdout, and stderr
between the host process and the in-VM command. When `VmCommand.tty = true`,
the exec call SHALL allocate a PTY on the host (or pass `-t` to `wsl --exec`
/ wire a VZ console device) so interactive shells work. The exit code of the
in-VM command SHALL be returned faithfully (no remapping, no "exit 1 means
generic failure" lossy translation).

@trace spec:vm-idiomatic-layer

#### Scenario: Non-TTY exec captures stdout
- **WHEN** the host calls `exec(VmCommand { argv: vec!["echo", "hello"], tty: false })`
- **THEN** the call SHALL return `ExitStatus { code: 0, stdout: b"hello\n", … }`

#### Scenario: TTY exec attaches a shell
- **WHEN** the host calls `exec(VmCommand { argv: vec!["podman", "exec", "-it", "tillandsias-foo-forge", "bash"], tty: true })`
- **THEN** the call SHALL spawn the command with stdin/stdout/stderr connected to the host PTY
- **AND** keystrokes typed on the host SHALL appear in the forge shell

#### Scenario: Exit code 137 (SIGKILL) is preserved
- **WHEN** the in-VM command is killed with `kill -9`
- **THEN** the host SHALL receive `ExitStatus { code: 137, … }` (not a generic "1")

### Requirement: `wait_ready` is event-driven, not polling
- **ID**: vm-idiomatic-layer.api.wait-ready-event-driven@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [vm-idiomatic-layer.invariant.wait-ready-no-busy-loop]

`VmRuntime::wait_ready` SHALL block until the VM is fully booted AND the
in-VM headless is listening on vsock port `42420`. It SHALL NOT busy-poll. On
WSL2 this is implemented by waiting on the `wsl --exec` process that spawns
the headless and then attempting a vsock connect with retry backoff
(250ms/500ms/1s/…). On VZ this is implemented via the VZ machine's state
change KVO observation.

@trace spec:vm-idiomatic-layer

#### Scenario: wait_ready returns on first successful vsock connect
- **WHEN** the host calls `wait_ready(Duration::from_secs(60))` after `start()`
- **THEN** the call SHALL return `Ok(())` within 2s of the in-VM headless emitting `app.started`

#### Scenario: wait_ready times out cleanly
- **WHEN** the in-VM headless fails to start within the timeout
- **THEN** `wait_ready` SHALL return `Err(VmError::ReadyTimeout)` exactly at the timeout boundary (±200ms)
- **AND** SHALL NOT have consumed >1% CPU during the wait

## Invariants

### Invariant: Trait methods are fixed
- **ID**: vm-idiomatic-layer.invariant.trait-methods-fixed
- **Expression**: `VmRuntime.methods == {provision, start, stop, exec, wait_ready}`
- **Measurable**: true

### Invariant: Trait is async and Send
- **ID**: vm-idiomatic-layer.invariant.trait-async-and-send
- **Expression**: `VmRuntime IS Send + Sync AND methods RETURN impl Future + Send`
- **Measurable**: true

### Invariant: No wsl.exe shellouts outside vm-layer
- **ID**: vm-idiomatic-layer.invariant.no-wsl-shellouts-outside-vm-layer
- **Expression**: `grep -rn Command::new("wsl") crates/ EXCEPT crates/tillandsias-vm-layer/src/wsl.rs RETURNS empty`
- **Measurable**: true

### Invariant: No VZ symbols outside vm-layer
- **ID**: vm-idiomatic-layer.invariant.no-vz-symbols-outside-vm-layer
- **Expression**: `grep -rn objc2_virtualization crates/ EXCEPT crates/tillandsias-vm-layer/src/vz.rs RETURNS empty`
- **Measurable**: true

### Invariant: Exec stdio is mapped
- **ID**: vm-idiomatic-layer.invariant.exec-stdio-mapped
- **Expression**: `VmCommand.tty == true => host_PTY_attached AND stdin/stdout/stderr forwarded`
- **Measurable**: true

### Invariant: Exit code fidelity
- **ID**: vm-idiomatic-layer.invariant.exit-code-fidelity
- **Expression**: `host_exit_code EQ guest_exit_code FOR_ALL exit_codes IN [0, 1, 127, 137, 143]`
- **Measurable**: true

### Invariant: wait_ready has no busy loop
- **ID**: vm-idiomatic-layer.invariant.wait-ready-no-busy-loop
- **Expression**: `wait_ready CPU_usage_during_wait < 1%`
- **Measurable**: true

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:cross-platform-terminal-attach` — exercises the `exec` TTY surface.
- `litmus:vm-shutdown-drains-forges` — exercises `stop(force=false)` then `stop(force=true)`.
- `litmus:vm-provisioning-idempotent` — exercises `provision` idempotency.
- `litmus:vsock-handshake` — exercises CID allocation set up by the layer.

## Litmus Chain

Smallest actionable boundary: `cargo test -p tillandsias-vm-layer
--filter vm_runtime::tests --strict`. Runtime entry boundary: spawning a
`LocalLinuxRuntime` fake from the host shell on Linux and running the trait
contract against it to validate the abstraction before real WSL/VZ runners
are exercised.

## Sources of Truth

- `cheatsheets/runtime/idiomatic-vm-exec.md` — wsl exec / vz exec semantics.
- `cheatsheets/runtime/wsl2-provisioning.md` — WSL2 lifecycle reference.
- `cheatsheets/runtime/vz-framework-provisioning.md` — VZ lifecycle reference.
- `crates/tillandsias-podman/` — discipline analog this crate mirrors.
- Plan: `/home/tlatoani/.claude/plans/stateless-riding-newt.md`.

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:vm-idiomatic-layer" crates/ --include="*.rs"
```
