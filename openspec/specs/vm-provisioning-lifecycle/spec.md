<!-- @trace spec:vm-provisioning-lifecycle -->
# vm-provisioning-lifecycle Specification

## Status

proposed
phase: 2

## Purpose

Specify the first-run provisioning, steady-state startup, and shutdown
contract for the Fedora 44 Core VM that hosts the in-VM
`tillandsias-headless` and the podman enclave on non-Linux hosts. On first
launch, the host downloads the Fedora 44 rootfs from the official Fedora
mirror and the matching `tillandsias-linux-x86_64` binary from our GitHub
release. The tray surfaces this as a single condensed status line — never as
a multi-step progress UI. On every tray launch the VM starts; on every tray
exit the VM is gracefully drained.

This spec is part of the Windows + macOS host-shell design wave. See plan:
`/home/tlatoani/.claude/plans/stateless-riding-newt.md`. Decision matrix row
13 establishes the condensed status UX; row 12 establishes the always-drain
shutdown contract; rows 4 and 5 establish the host-mirror / GitHub-release
sourcing.

Cross-references:
- `vm-idiomatic-layer` — backend implementing `provision`, `start`, `stop`.
- `host-shell-architecture` — owner of the status surface and shutdown sequencing.
- `windows-native-tray`, `macos-native-tray` — UI surfaces consuming the status text.
- `vsock-transport` — used by host to send `VmShutdownRequest` during drain.
- `tillandsias-vault` — vault container started as part of provisioning.

## Requirements

### Requirement: First-run provisioning downloads Fedora rootfs and tillandsias binary
- **ID**: vm-provisioning-lifecycle.provision.first-run-downloads@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [vm-provisioning-lifecycle.invariant.rootfs-from-fedora-mirror, vm-provisioning-lifecycle.invariant.binary-from-github-release, vm-provisioning-lifecycle.invariant.sha-verified]

On a fresh host with no prior tillandsias VM, the host shell SHALL download:
1. The Fedora 44 rootfs tarball from
   `https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Container/x86_64/images/Fedora-Container-Base-Generic.44-*.x86_64.tar.xz`
   (latest patch revision discovered via the directory listing or a pinned
   manifest), cached at
   `~/.local/share/tillandsias/rootfs-fedora-44-<sha256>.tar.xz` (on macOS:
   `~/Library/Application Support/tillandsias/rootfs-…`; on Windows:
   `%LOCALAPPDATA%\tillandsias\rootfs-…`).
2. The matching `tillandsias-linux-x86_64` static binary from
   `https://github.com/8007342/tillandsias/releases/download/v<host-version>/tillandsias-linux-x86_64`.

Both downloads SHALL be verified against an expected SHA256 published in
`assets/provisioning-manifest.json` (committed to the repo per release).
The downloads SHALL be resumable on transient network failure (HTTP range
requests).

@trace spec:vm-provisioning-lifecycle

#### Scenario: Fresh host downloads both artifacts
- **WHEN** the tray launches on a host with no `~/.local/share/tillandsias/rootfs-*` and no installed VM
- **THEN** the host SHALL fetch the Fedora rootfs tarball from `dl.fedoraproject.org`
- **AND** SHALL fetch the `tillandsias-linux-x86_64` binary from the GitHub release matching the host tray version
- **AND** both downloads SHALL complete with checksums matching `assets/provisioning-manifest.json`

#### Scenario: Network failure resumes on retry
- **WHEN** a download is interrupted at 60% completion
- **THEN** the next retry SHALL issue an HTTP `Range: bytes=<offset>-` request
- **AND** SHALL resume from the interruption offset

#### Scenario: Checksum mismatch aborts provisioning
- **WHEN** a downloaded artifact's SHA256 does not match the manifest
- **THEN** the host SHALL delete the partial file
- **AND** SHALL surface `🥀 Provisioning failed: rootfs checksum mismatch` in the menu
- **AND** SHALL provide a "Retry" sub-item

### Requirement: Provisioning surfaces as a single condensed status line
- **ID**: vm-provisioning-lifecycle.ux.condensed-status@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [vm-provisioning-lifecycle.invariant.single-status-menu-item, vm-provisioning-lifecycle.invariant.status-rolls-text-not-items]

During provisioning, the tray menu SHALL display exactly ONE status item
that rolls through human-readable phase text. Sub-steps SHALL NOT be exposed
as separate menu items, progress bars, or notification toasts. The status
text SHALL transition through at least these phases (the exact wording is
fixed in the host shell — verbatim):
- `🔵 Setting up Fedora Linux…` (umbrella; default while any of the below is happening)
- `🔵 Downloading Fedora rootfs…` (during the rootfs HTTP fetch)
- `🔵 Downloading Tillandsias…` (during the binary HTTP fetch)
- `🔵 Installing Tillandsias…` (during `wsl --import` / VZ rootfs unpack)
- `🔵 Starting Fedora Linux…` (during the VM boot)
- `🔵 Connecting…` (during the vsock handshake)
- (transition to standard ready menu)

On failure: `🥀 Provisioning failed: <reason>` with sub-items "Retry" and
"Open log".

@trace spec:vm-provisioning-lifecycle, spec:host-shell-architecture

#### Scenario: Menu shows one status item throughout provisioning
- **WHEN** provisioning is in progress
- **THEN** the menu SHALL contain a single top-level item whose label matches one of the seven verbatim phase strings
- **AND** the menu SHALL NOT show a progress bar, percentage, or separate sub-items per phase

#### Scenario: Status text transitions through phases
- **WHEN** the rootfs download completes and the binary download begins
- **THEN** the status text SHALL flip from `🔵 Downloading Fedora rootfs…` to `🔵 Downloading Tillandsias…` within 100ms
- **AND** the menu SHALL NOT briefly show both phases

#### Scenario: Failure surfaces retry option
- **WHEN** any provisioning phase fails
- **THEN** the menu item label SHALL change to `🥀 Provisioning failed: <reason>` (max 80 chars; longer reasons truncated with ellipsis)
- **AND** two sub-items SHALL appear: `Retry` and `Open log` (the latter opens the provisioning log file in the host's default text editor)

### Requirement: Provisioning is idempotent
- **ID**: vm-provisioning-lifecycle.provision.idempotency@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [vm-provisioning-lifecycle.invariant.provision-idempotent, vm-provisioning-lifecycle.invariant.cache-keyed-by-sha]

Calling `VmRuntime::provision()` on a host where provisioning has already
completed SHALL be a no-op: no re-download, no re-import of the rootfs, no
recreation of the VM. The host SHALL detect prior provisioning by checking:
- The cached rootfs file exists at the SHA-keyed path and its checksum still matches.
- The cached binary exists and its checksum still matches.
- The WSL distro `tillandsias` is registered (Windows) OR the VZ rootfs disk image exists at the expected path (macOS).

@trace spec:vm-provisioning-lifecycle

#### Scenario: Second provision call is a no-op
- **WHEN** `provision()` is called on a host where all three checks pass
- **THEN** the call SHALL return `Ok(())` within 500ms
- **AND** SHALL emit NO network requests (verified by injecting a refusing HTTP client into the test)
- **AND** SHALL emit NO `wsl --import` or VZ disk-creation operations

#### Scenario: Stale cache triggers re-download
- **WHEN** the manifest pins a new SHA but the cached file matches the old SHA
- **THEN** `provision()` SHALL re-download the artifact matching the new SHA
- **AND** SHALL leave the old cached file in place (cleanup is a separate maintenance task)

#### Scenario: Distro removed externally triggers re-import
- **WHEN** the user manually runs `wsl --unregister tillandsias` and re-launches the tray
- **THEN** `provision()` SHALL detect the missing distro
- **AND** SHALL re-import from the cached rootfs (no re-download of the rootfs itself, since the cached file is still valid)

### Requirement: Tray exit triggers graceful drain
- **ID**: vm-provisioning-lifecycle.shutdown.graceful-drain@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [vm-provisioning-lifecycle.invariant.shutdown-no-opt-out, vm-provisioning-lifecycle.invariant.forge-drain-budget-10s-each, vm-provisioning-lifecycle.invariant.vm-hard-stop-30s]

On tray exit, the host shell SHALL execute the following drain sequence
exactly:
1. Send `ControlMessage::VmShutdownRequest { drain_timeout_ms: 10_000 }` over vsock.
2. The in-VM headless SHALL `podman stop --time=10` every forge container in parallel — SIGTERM each, wait up to 10s, then SIGKILL.
3. The in-VM headless SHALL revoke every per-container vault token (see `tillandsias-vault`).
4. The in-VM headless SHALL stop the vault container, then the git, proxy, and inference containers in dependency order.
5. The in-VM headless SHALL exit.
6. The host shell SHALL wait up to 30s total (wall clock from step 1) for the VM to report stopped via `VmRuntime::wait_stopped`.
7. If the 30s wall is breached, the host shell SHALL call `VmRuntime::stop(force=true)` which translates to `wsl --terminate tillandsias` on Windows / `VZVirtualMachine.forceStop` on macOS.

There SHALL be no opt-out for the shutdown-on-tray-exit contract in v1. A
future setting can be added if users want persistent VMs.

@trace spec:vm-provisioning-lifecycle, spec:vm-idiomatic-layer

#### Scenario: Single forge drains within 10s
- **WHEN** the user quits the tray while one forge container is running an idle bash shell
- **THEN** the forge SHALL receive SIGTERM within 100ms of `VmShutdownRequest`
- **AND** the forge SHALL exit within 10s
- **AND** the VM SHALL stop within 30s wall clock from `VmShutdownRequest`

#### Scenario: Stuck forge triggers hard stop on time budget
- **WHEN** the forge ignores SIGTERM (e.g. a buggy agent process traps it)
- **THEN** the in-VM headless SHALL SIGKILL the forge at the 10s boundary
- **AND** if the VM still hasn't stopped at 30s, the host SHALL invoke `VmRuntime::stop(force=true)`
- **AND** the host process SHALL exit within 31s of the user clicking Quit

#### Scenario: No opt-out in v1
- **WHEN** the user looks for a "keep VM running" toggle in the menu or config
- **THEN** no such option SHALL exist in the v1 menu structure or config schema
- **AND** the spec's invariant `shutdown-no-opt-out` SHALL gate any future addition behind an explicit spec revision

### Requirement: Provisioning log is captured for diagnostics
- **ID**: vm-provisioning-lifecycle.observability.provision-log@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [vm-provisioning-lifecycle.invariant.log-file-path-deterministic, vm-provisioning-lifecycle.invariant.log-redacted]

Every provisioning attempt SHALL append to a structured log file at
`<host-data-dir>/provision.log`. Log entries SHALL be JSON Lines and SHALL
include the phase, timestamp, byte counts for downloads, and the SHA of any
artifact involved. The log SHALL NOT contain the installation UUID, vault
unseal key, or any credential material.

@trace spec:vm-provisioning-lifecycle

#### Scenario: Each phase emits a log entry
- **WHEN** a full provisioning runs to completion
- **THEN** `provision.log` SHALL contain at least one JSON entry per phase from the condensed-status list
- **AND** each entry SHALL include `{ "phase": "...", "ts": <unix>, "ok": true|false }`

#### Scenario: Log does not leak the installation UUID
- **WHEN** the log file is grepped for the host's installation UUID
- **THEN** zero matches SHALL be found

#### Scenario: Open log menu item opens the right file
- **WHEN** the user clicks `Open log` from a failed provisioning menu
- **THEN** the host's default text editor SHALL open `<host-data-dir>/provision.log`

## Invariants

### Invariant: Rootfs comes from the Fedora mirror
- **ID**: vm-provisioning-lifecycle.invariant.rootfs-from-fedora-mirror
- **Expression**: `rootfs_url MATCHES https://dl\.fedoraproject\.org/.*Fedora-Container-Base-Generic\.44-.*\.tar\.xz`
- **Measurable**: true

### Invariant: Binary comes from a GitHub release
- **ID**: vm-provisioning-lifecycle.invariant.binary-from-github-release
- **Expression**: `binary_url MATCHES https://github\.com/8007342/tillandsias/releases/download/v.*/tillandsias-linux-x86_64`
- **Measurable**: true

### Invariant: Downloads are SHA-verified
- **ID**: vm-provisioning-lifecycle.invariant.sha-verified
- **Expression**: `download.complete EVENT TRIGGERS sha256_check AGAINST assets/provisioning-manifest.json`
- **Measurable**: true

### Invariant: Single status menu item
- **ID**: vm-provisioning-lifecycle.invariant.single-status-menu-item
- **Expression**: `provisioning_active => menu.top_level_items.count_matching(status_text) == 1`
- **Measurable**: true

### Invariant: Status rolls text, not items
- **ID**: vm-provisioning-lifecycle.invariant.status-rolls-text-not-items
- **Expression**: `phase_transition CHANGES status_item.label AND DOES_NOT add OR remove items`
- **Measurable**: true

### Invariant: Provision is idempotent
- **ID**: vm-provisioning-lifecycle.invariant.provision-idempotent
- **Expression**: `provision_call[N >= 2] WHERE checks_pass EMITS no network OR import operations`
- **Measurable**: true

### Invariant: Cache is keyed by SHA
- **ID**: vm-provisioning-lifecycle.invariant.cache-keyed-by-sha
- **Expression**: `rootfs_cache_path MATCHES .*/rootfs-fedora-44-[0-9a-f]{64}\.tar\.xz`
- **Measurable**: true

### Invariant: Shutdown has no opt-out
- **ID**: vm-provisioning-lifecycle.invariant.shutdown-no-opt-out
- **Expression**: `v1_config_schema CONTAINS no field_named_like(keep_vm_running|persistent_vm)`
- **Measurable**: true

### Invariant: Forge drain budget is 10s each
- **ID**: vm-provisioning-lifecycle.invariant.forge-drain-budget-10s-each
- **Expression**: `forge_sigterm → forge_sigkill_or_exit DELTA <= 10s`
- **Measurable**: true

### Invariant: VM hard-stop at 30s wall
- **ID**: vm-provisioning-lifecycle.invariant.vm-hard-stop-30s
- **Expression**: `tray_quit → host_process_exit DELTA <= 31s`
- **Measurable**: true

### Invariant: Log file path is deterministic
- **ID**: vm-provisioning-lifecycle.invariant.log-file-path-deterministic
- **Expression**: `provision_log_path EQ <host-data-dir>/provision.log`
- **Measurable**: true

### Invariant: Log is redacted
- **ID**: vm-provisioning-lifecycle.invariant.log-redacted
- **Expression**: `grep installation_uuid provision.log RETURNS empty`
- **Measurable**: true

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:vm-provisioning-idempotent` — primary idempotency verification.
- `litmus:vm-shutdown-drains-forges` — graceful drain contract.
- `litmus:vsock-handshake` — transitively asserts the VM reaches "Ready" after `start`.

## Litmus Chain

Smallest actionable boundary: `cargo test -p tillandsias-host-shell
provisioning::tests::cache_hit_skips_download --strict`. Runtime entry
boundary: running the tray binary against a `LocalLinuxRuntime` fake on
Linux, then transitioning to a real WSL/VZ run in Phase 4/5.

## Sources of Truth

- `cheatsheets/runtime/wsl2-provisioning.md` — WSL2 import mechanics.
- `cheatsheets/runtime/vz-framework-provisioning.md` — VZ guest mechanics.
- `cheatsheets/runtime/idiomatic-vm-exec.md` — exec semantics during init.
- `assets/provisioning-manifest.json` — pinned SHA256s per release.
- Plan: `/home/tlatoani/.claude/plans/stateless-riding-newt.md`.

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:vm-provisioning-lifecycle" crates/ scripts/ --include="*.rs" --include="*.sh"
```
