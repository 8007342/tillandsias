## MODIFIED Requirements

### Requirement: Tray exit triggers graceful drain

On tray exit, the host shell SHALL execute the drain sequence exactly as
before (VmShutdownRequest, forge stop, token revocation, shared-container
stop, headless exit, 30s wall, forced stop), with ONE exception: an exit
performed as the OLD side of an upgrade handoff (`--upgrade-handoff`, see
`app-lifecycle`) SHALL NOT send `VmShutdownRequest`, SHALL NOT stop any
container, and SHALL leave the guest running for the new tray to adopt. The
"no opt-out" invariant is preserved for every other exit (Quit, signal,
crash) and no configuration field enables a persistent VM: the exception is
an argument of a specific relaunch, not a setting. On a platform where the
guest cannot outlive the tray process (a VM hosted in-process), the handoff
SHALL be refused with `deferred:vm-in-process` and the ordinary drain SHALL
be offered to the operator — never performed silently.

@trace spec:vm-provisioning-lifecycle, spec:vm-idiomatic-layer, spec:app-lifecycle

#### Scenario: Ordinary quit still drains
- **WHEN** the operator quits the tray
- **THEN** the full drain sequence runs and the VM / distro is stopped
  (positive control, unchanged).

#### Scenario: Handoff exit leaves the WSL distro running
- **WHEN** a Windows tray at version A exits as the old side of a handoff
- **THEN** `wsl --list --running` still lists the distro,
  `tillandsias-headless.service` is still active, and the containers inside
  are unchanged.
- Pre-fix result: FAILS — every quit runs `WslLifecycle::graceful_shutdown`
  (`wsl_lifecycle.rs:665`) → `wsl --terminate` (`wsl.rs:1120`).

#### Scenario: In-process VM refuses the handoff loudly
- **WHEN** a macOS tray whose VM lives in-process (`vz.rs:2884-2885`) is
  asked to hand off
- **THEN** it reports `deferred:vm-in-process`, performs no drain, and offers
  the drain-and-relaunch path.
- Pre-fix result: FAILS — no handoff exists; `quit_with_drain`
  (`action_host.rs:1211`) is the only exit.

## ADDED Requirements

### Requirement: Guest headless binary can be hot-installed into a running guest

A staged headless binary SHALL be installed into the running guest by atomic
rename (never by in-place overwrite of the running ELF), and the daemon SHALL
be re-executed under a unit whose kill scope excludes container processes
(`KillMode=process`). Container processes SHALL survive the re-exec; the set
of running container ids before and after SHALL be equal. The staged binary
SHALL be pinned to the host's version; the `releases/latest` fallback SHALL be
removed from the fetch path. On macOS the install SHALL trigger from a new
stage in the virtio-fs share without a reboot; on Windows
`reconcile_adopted_guest` SHALL install without stopping the unit first.

@trace spec:vm-provisioning-lifecycle

#### Scenario: Re-exec keeps containers
- **WHEN** a new headless binary is staged while three containers run in the
  guest
- **THEN** after the daemon re-exec the set of running container ids is
  unchanged and the host reconnects on the control wire within 10 seconds.
- Pre-fix result: UNMEASURED — neither unit (`vz.rs:1240`,
  `wsl_lifecycle.rs:1875`) sets `KillMode=`; Windows stops the unit before
  writing (`wsl_lifecycle.rs:1124`, `cat > path` at `:2115`).

#### Scenario: Stage on a running macOS guest installs without reboot
- **WHEN** the macOS tray stages a newer binary into the virtio-fs share
- **THEN** the guest installs it and re-execs the daemon without a VM reboot,
  and the provision-state share reports the new sha256.
- Pre-fix result: FAILS — installed only by the boot-time fetch oneshot
  (`vz.rs:1203`).

#### Scenario: The fallback is pinned
- **WHEN** the staged binary is absent and the guest fetches one
- **THEN** the URL names `v<host-version>`, never `releases/latest`.
- Pre-fix result: FAILS — `vz.rs:1122` uses `releases/latest`.
