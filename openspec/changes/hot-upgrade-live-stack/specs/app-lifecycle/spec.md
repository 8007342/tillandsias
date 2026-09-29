## MODIFIED Requirements

### Requirement: shutdown_all removes containers AND destroys the enclave network

`shutdown_all()` SHALL stop and remove every container it OWNS — decided by
the `io.tillandsias.owner` label (below), with the name predicate accepted
only for unlabelled legacy objects — before destroying the enclave network,
and SHALL NOT stop or remove any container it does not own however it is
named. `cleanup_enclave_network()` SHALL use `podman network rm -f`. After
`shutdown_all()` returns, `podman ps -a --filter label=io.tillandsias.owner=<this uuid>`
MUST be empty and `podman network exists tillandsias-enclave` MUST be false.
An exit performed as the OLD side of an upgrade handoff (below) SHALL NOT run
`shutdown_all()` at all: the stack is the new instance's to adopt.

#### Scenario: Stop + remove, then destroy network
- **WHEN** `shutdown_all()` iterates the owned containers
- **THEN** each is stopped (SIGTERM with 10s grace, then SIGKILL)
- **AND** each is removed from podman's records
- **AND** the enclave network is destroyed with `network rm -f`
- **AND** after completion, `podman ps -a --filter label=io.tillandsias.owner=<this uuid>`
  returns no results

#### Scenario: Exited container from a prior crash is swept
- **WHEN** a previous tillandsias session crashed leaving an owned container
  in `exited` state still attached to `tillandsias-enclave`
- **AND** a fresh tray process starts and then quits via the tray menu
- **THEN** the orphan sweep in `shutdown_all()` removes the exited container
- **AND** the enclave network is destroyed cleanly on the same quit cycle

#### Scenario: A toolbox with our prefix survives shutdown
- **WHEN** containers named `tillandsias-builder` and `tillandsias-nix`
  carrying `com.github.containers.toolbox=true` are running during shutdown
- **THEN** neither is stopped, removed, or listed as managed.
- Pre-fix result: PASSES by name today only because 936-kdev narrowed the
  predicate (`main.rs:7497`); `reset_guest_scope` (`main.rs:10029`) still
  matches them by the bare prefix — FAILS there.

#### Scenario: Handoff exit skips the sweep
- **WHEN** the instance exits because a newer instance completed the upgrade
  handoff
- **THEN** `shutdown_all()` is not invoked, `podman ps -q` is unchanged, and
  the exit code is 0.
- Pre-fix result: FAILS — every exit runs `graceful_shutdown_async`
  (`main.rs:19692`).

## ADDED Requirements

### Requirement: Every created podman object carries ownership labels

Every container, volume and network the binary creates SHALL carry
`io.tillandsias.owner=<installation-uuid-v1>`, `io.tillandsias.version=<VERSION>`
and `io.tillandsias.role=<role>`. Ownership predicates (shutdown sweep, reset
scope, stack management, stale cleanup) SHALL decide by the owner label; a
name-prefix match is accepted only for objects without any label and SHALL be
logged as `legacy-unlabelled`. An object carrying a toolbox label
(`com.github.containers.toolbox`) SHALL never be treated as owned even when it
also carries ours.

@trace spec:app-lifecycle

#### Scenario: Owned container with a foreign name is managed
- **WHEN** a container named `mirror-x` carries `io.tillandsias.owner=<this uuid>`
- **THEN** the shutdown sweep and the reset scope treat it as managed.
- Pre-fix result: FAILS — no container carries an owner label; the only
  container label in the tree is the proxy's `tillandsias.ca-generation`
  (`main.rs:3713`).

#### Scenario: Every launched container is labelled
- **WHEN** `--init` and one forge launch complete
- **THEN** `podman inspect` on every container the headless started shows the
  three `io.tillandsias.*` labels.
- Pre-fix result: FAILS.

### Requirement: Upgrade handoff transfers the stack without stopping it

A new instance started with `--upgrade-handoff` SHALL request a handoff from
the running instance over the control socket. The running instance SHALL stop
accepting lane launches, write a handoff manifest, release the singleton lock
and exit 0 WITHOUT invoking `shutdown_all` / `graceful_shutdown_async`. The
new instance SHALL adopt every owned container it finds running, re-deriving
state from `podman inspect` and treating the manifest as a hint. The
pre-existing SIGTERM takeover (`singleton.rs:192`) SHALL remain only for the
non-handoff case and SHALL be logged as `takeover:kill`. When no instance
answers within 5 seconds the new instance SHALL exit non-zero with
`refused:upgrade:no-handoff-peer`, print the relaunch command, and SHALL NOT
send SIGTERM.

@trace spec:app-lifecycle

#### Scenario: Handoff keeps every managed container running
- **WHEN** an instance at version A holds a running forge, vault, proxy and
  git mirror, and an instance at version B starts with `--upgrade-handoff`
- **THEN** `podman ps -q` before and after are equal sets, instance A exited
  0, and instance B's `--diagnose` lists the four containers as `adopted`.
- Pre-fix result: FAILS — instance B SIGTERMs A (`singleton.rs:134-146`) and
  A stops every managed container (`main.rs:19692`); the forge runs `--rm`
  (`main.rs:8027`) and is gone.

#### Scenario: No handoff peer refuses loudly
- **WHEN** the running instance does not answer within 5 seconds
- **THEN** the new instance exits non-zero with `refused:upgrade:no-handoff-peer`,
  prints `tillandsias --quit && tillandsias`, and has sent no signal.
- Pre-fix result: FAILS — SIGTERM is unconditional.

### Requirement: Shared-stack version skew is explicit and bounded

After adoption, each shared container's `io.tillandsias.version` SHALL be
classified against the binary as `Same`, `Compatible` (within the declared
window `WINDOW_DAYS`) or `Incompatible`. An `Incompatible` shared container
SHALL be drained and recreated only when no running forge depends on it;
otherwise the swap SHALL be reported as `deferred:skew:<name>` and retried
when the dependency count reaches zero. Forge containers SHALL never be
swapped by this policy. `--diagnose` SHALL print the skew table.

@trace spec:app-lifecycle

#### Scenario: Skew with a dependent forge is deferred
- **WHEN** the proxy runs an image outside the window and one forge is running
- **THEN** `--diagnose` shows `proxy: deferred:skew`, the proxy container id
  is unchanged, and the forge is untouched.
- Pre-fix result: FAILS — reuse is by name only (`main.rs:3836`); no report.

#### Scenario: Skew with no dependents is swapped
- **WHEN** the proxy runs an image outside the window and no forge is running
- **THEN** the proxy is recreated on `:v<VERSION>` and its readiness probe
  passes before the outcome is reported as `upgraded`.
- Pre-fix result: FAILS — only the router is compared to its tag
  (`main.rs:6241`).
