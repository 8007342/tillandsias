<!-- @trace spec:dev-build -->
<!-- # freshness: auditor=windows-yolanda-fable5-20260816t0721z date=2026-08-16 verdict=updated scope=standing per-cycle audit — the Host-native requirement contradicted build.sh's deliberate re-exec discipline (with-tillandsias-builder.sh toolbox on Silverblue, methodology development_environment_lifecycle 2026-08-13; with-wsl2-builder.sh tillandsias-build WSL2 distro on Windows, operator directive 2026-07-15; both sourced at build.sh:32,39). Requirement rewritten to specify the transparent substrate re-exec instead of forbidding it; every other requirement re-read and confirmed current -->
# dev-build Specification

## Status

active

## Purpose
Define the build pipeline for local development, install, and CI gating. The
pipeline MUST keep cheap pre-build validation separate from the expensive
post-build smoke so measurable debt is visible instead of folded into one blob.
## Requirements
### Requirement: Transparent build-substrate re-exec
<!-- req-id: 2bf34bb3 -->
The build script SHALL detect the host and transparently re-exec into the
platform's dedicated build substrate when the host base OS is not itself the
build environment: the `tillandsias-builder` toolbox on immutable Silverblue
hosts, and the `tillandsias-build` WSL2 distro on Windows hosts (each created
idempotently on first use, never on the runtime/smoke substrate). On ordinary
mutable Linux the build SHALL run directly on the host. The caller-visible
contract is identical on every platform — same flags, same outputs — and the
normal build path MUST NOT require a Nix shell.

#### Scenario: First run on a mutable Fedora workstation
- **WHEN** `./build.sh` is run from a mutable Linux host with the required Rust toolchain and Podman available
- **THEN** the host Podman runtime wrapper SHALL initialize writable runtime state
- **AND** Rust build commands SHALL execute directly on the host
- **AND** no build container SHALL be created as part of the build path

#### Scenario: Run on an immutable Silverblue host
- **WHEN** `./build.sh` is run on a Silverblue (ostree) host
- **THEN** the script SHALL re-exec itself inside the `tillandsias-builder` toolbox, creating and provisioning it idempotently when absent

#### Scenario: Run on a Windows host
- **WHEN** `./build.sh` is run from Git Bash/MSYS on Windows
- **THEN** the script SHALL re-exec itself inside the `tillandsias-build` WSL2 distro, importing it idempotently from the cached rootfs when absent
- **AND** the runtime `tillandsias` distro MUST NOT be used as the build substrate (destructive smoke e2e unregisters it)

#### Scenario: Portable install prerequisites
- **WHEN** `./build.sh --install` is run
- **THEN** the host SHALL provide a rustup-managed toolchain with the `x86_64-unknown-linux-musl` target installed
- **AND** the build SHALL fail early with a corrective command if that target is absent

#### Scenario: Subsequent runs
- **WHEN** `./build.sh` is run again
- **THEN** the build SHALL reuse the host's installed toolchain and ordinary Cargo cache
- **AND** no container bootstrap overhead SHALL be introduced

### Requirement: Debug build by default
<!-- req-id: c42b5827 -->
Running `./build.sh` with no flags SHALL perform a debug workspace build directly on the host.

#### Scenario: Default invocation
- **WHEN** `./build.sh` is run with no arguments
- **THEN** `cargo build --workspace` SHALL run directly on the host

### Requirement: Release build
<!-- req-id: 103640a9 -->
The `--release` flag SHALL produce a Tauri release bundle.

#### Scenario: Release build
- **WHEN** `./build.sh --release` is run
- **THEN** the release command SHALL run directly on the host

### Requirement: Test execution
<!-- req-id: da441904 -->
The `--test` flag SHALL run the full test suite.

#### Scenario: Run tests
- **WHEN** `./build.sh --test` is run
- **THEN** `cargo test --workspace` SHALL run directly on the host and SHALL report results

### Requirement: Clean build
<!-- req-id: 210a9170 -->
The `--clean` flag SHALL remove all build artifacts before building.

#### Scenario: Clean then build
- **WHEN** `./build.sh --clean` is run
- **THEN** `cargo clean` SHALL run first, then the default build SHALL proceed

#### Scenario: Clean with release
- **WHEN** `./build.sh --clean --release` is run
- **THEN** `cargo clean` SHALL run first, then a release build SHALL proceed

### Requirement: Build churn directories opt out of copy-on-write on btrfs
<!-- req-id: bfc2d453 -->
On a btrfs host, the build artifact directory (`target/`) and the rootless
container layer store (`~/.local/share/containers/storage/overlay`) SHALL
carry the `nodatacow` attribute (`chattr +C`). These trees are rebuildable
churn, not history: every cargo artifact and container layer write otherwise
pays copy-on-write + compression + checksum amplification before reaching the
device, which is what saturated a DRAM-less NVMe on macuahuitl during
parallel builds (2026-08-30, `io full avg300=21.6%` in PSI while CPU pressure
read 0.00 — the whole desktop stuttered on a "fast" drive at 78% capacity).
The attribute costs nothing to hold and disables nothing these trees need:
compression saves little on binaries, and checksums protect data that a
rebuild regenerates anyway.

`chattr +C` applies only to files created AFTER it is set. Setting it on a
live directory is therefore safe and immediately effective for the churn
(new artifacts, new layers) while pre-existing files keep CoW until their
next full recreation — a `--clean` or a store reset completes the migration
naturally. Do not wipe either tree just to migrate it.

#### Scenario: Provisioning a Linux build host on btrfs
- **WHEN** a build substrate is provisioned (or first checked) on a btrfs filesystem
- **THEN** `target/` and the rootless overlay store SHALL have the `C` attribute (`lsattr -d` shows it)
- **AND** setting it SHALL NOT require wiping existing contents

#### Scenario: Non-btrfs host
- **WHEN** the filesystem is not btrfs (ext4, xfs, WSL2 ext4)
- **THEN** the attribute is not applicable and the check SHALL pass as a named skip, not a failure

### Requirement: Install to local path
<!-- req-id: ed8883a6 -->
The `--install` flag SHALL build a release binary and copy it to `~/.local/bin/` with only non-executable supporting files.

#### Scenario: Install binary
- **WHEN** `./build.sh --install` is run
- **THEN** the binary and runtime libraries SHALL be installed to `~/.local/bin/` and `~/.local/lib/tillandsias/`
- **AND** icons SHALL be installed for the desktop launcher
- **AND** no shell scripts, flake files, or image sources MUST be copied to `~/.local/share/tillandsias/`

### Requirement: CI full runs in explicit phases
<!-- req-id: c90e3cc9 -->
The `--ci-full` path SHALL run in named phases so pre-build contract checks, the
post-build smoke, and the runtime residual litmus suite remain separately
measurable.

#### Scenario: Pre-build phase
- **WHEN** `./build.sh --ci-full --install` starts
- **THEN** pre-build litmus SHALL run before the install/build boundary
- **AND** command-shape and static contract tests SHALL be gated there

#### Scenario: Post-build phase
- **WHEN** the build/install boundary completes successfully
- **THEN** the post-build smoke SHALL run against the installed binary
- **AND** it SHALL exercise the representative end-to-end stack exactly once

#### Scenario: Runtime residual phase
- **WHEN** the post-build smoke passes
- **THEN** the runtime residual litmus suite MAY run as a separate phase
- **AND** its failures SHALL remain visible and not be conflated with the pre-build or smoke phases

### Requirement: Post-build status check smoke
<!-- req-id: d5442e49 -->
The installed binary SHALL support a `--status-check` smoke path that launches
the enclave stack, runs an embedded in-container health probe, and prints
verifiable service-online evidence before cleaning up.

#### Scenario: Status check after init
- **WHEN** the user runs `tillandsias --init --debug --status-check`
- **THEN** image builds SHALL complete first
- **AND** the orchestrated stack SHALL start
- **AND** the embedded health probe SHALL report online services from inside the container
- **AND** the command SHALL exit cleanly after cleanup

### Requirement: Remove installed binary
<!-- req-id: c63aab80 -->
The `--remove` flag SHALL remove the installed binary from `~/.local/bin/`.

#### Scenario: Remove binary
- **WHEN** `./build.sh --remove` is run
- **THEN** `~/.local/bin/tillandsias` SHALL be deleted if it exists

### Requirement: Wipe caches and artifacts
<!-- req-id: 7bf6bb37 -->
The `--wipe` flag SHALL remove all caches and build artifacts.

#### Scenario: Wipe everything
- **WHEN** `./build.sh --wipe` is run
- **THEN** `target/`, `~/.cache/tillandsias/`, and any temporary build files SHALL be removed


### Requirement: Installer triggers init
<!-- req-id: 62f10e6f -->
The installer script SHALL run `tillandsias --init` as a background task after installation.

#### Scenario: Fresh install
- **WHEN** `install.sh` completes the binary installation
- **THEN** `tillandsias --init` SHALL be spawned as a background process
- **AND** the installer SHALL print a message indicating images are building in the background

### Requirement: Cross-platform build documentation
<!-- req-id: 4580ef6c -->
The project SHALL include documentation at `docs/cross-platform-builds.md` explaining the cross-platform build strategy and legal constraints.

#### Scenario: macOS infeasibility documented
- **WHEN** a developer reads `docs/cross-platform-builds.md`
- **THEN** they SHALL find a clear explanation that macOS cross-compilation from Linux is not feasible due to Apple EULA restrictions and Tauri's native framework requirements

#### Scenario: Windows cross-compilation documented
- **WHEN** a developer reads `docs/cross-platform-builds.md`
- **THEN** they SHALL find instructions for using `build-windows.sh` with its limitations (unsigned, experimental)

#### Scenario: CI-first strategy documented
- **WHEN** a developer reads `docs/cross-platform-builds.md`
- **THEN** they SHALL understand that CI (GitHub Actions) remains the authoritative build pipeline for all platforms, and local cross-compilation is supplementary for troubleshooting

### Requirement: Install exits with deterministic exit codes
<!-- req-id: 8e3a5622 -->
The `--install` flag SHALL exit with code 0 (success) or 1 (failure), enabling chaining with subsequent commands.

#### Scenario: Install succeeds
- **WHEN** `./build.sh --install` completes successfully
- **THEN** the command SHALL exit with code 0
- **AND** critical images SHALL be built and binary SHALL be installed
- **AND** a `[build] SUCCESS` message SHALL be printed to stdout
- **AND** MUST be safe to chain: `./build.sh --install && tillandsias --init --debug && tillandsias /path`

#### Scenario: Install fails
- **WHEN** `./build.sh --install` fails (image build failed or binary copy failed)
- **THEN** the command SHALL exit with code 1
- **AND** a `[build] ERROR` message SHALL be printed to stderr
- **AND** MUST be safe for error handling: `./build.sh --install || echo "build failed; fix errors above"`

### Requirement: Transparent HTTPS caching via dev proxy
<!-- req-id: ff1435ce -->
The build script SHALL automatically set up and manage a local caching proxy (tillandsias-dev-proxy) for transparent HTTPS caching of build dependencies (apt, cargo, OCI, rustup). The proxy SHALL be idempotent and resilient.

#### Scenario: First build with no proxy image
- **WHEN** `./build.sh` runs for the first time and `tillandsias-proxy` image does not exist
- **THEN** the build script SHALL automatically rebuild the proxy image via `scripts/build-image.sh proxy`
- **AND** SHALL start a dev proxy container at `127.0.0.1:3129`
- **AND** SHALL inject the HTTP_PROXY and HTTPS_PROXY env vars for all downstream build operations

#### Scenario: Subsequent builds with proxy running
- **WHEN** `./build.sh` runs and `tillandsias-dev-proxy` container is already running
- **THEN** the build script SHALL skip container startup (idempotent)
- **AND** SHALL verify proxy health via port 3129 check
- **AND** SHALL proceed with build

#### Scenario: Proxy startup failure
- **WHEN** dev proxy fails to start or fails health check
- **THEN** the build script SHALL log the failure and proxy logs
- **AND** SHALL continue without proxy (non-fatal, builds still work but are slower)
- **AND** SHALL NOT block the build

#### Scenario: Container networking via slirp4netns
- **WHEN** AppImage builder container runs inside rootless podman
- **THEN** it SHALL access the host-side proxy via `host.containers.internal:3129`
- **AND** the proxy SHALL be bound to all interfaces (`:3129`) so containers can reach it through the slirp4netns bridge


## Sources of Truth

- `cheatsheets/build/cargo.md` — Cargo reference and patterns
- `cheatsheets/build/nix-flake-basics.md` — Nix Flake Basics reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:podman-build-command-shape` — Validate pre-build command-shape contract for build-image.sh
- `litmus:status-check-stack-verification` — Validate post-build smoke launches the stack and reports service-online evidence
- `litmus:environment-isolation`
- `litmus:build-ci-dispatch-shape` — Pin single-dispatch CI phases and completed-evidence reuse

Gating points:
- Dev builds are isolated from host system; no build artifacts leak to host
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:dev-build" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
