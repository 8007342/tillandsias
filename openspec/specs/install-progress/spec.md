<!-- @trace spec:install-progress -->

## Status

active

## Requirements

### Curl installer is userspace-only on Linux

The curl installer MUST install the released Linux musl binary into a safe
current-user bin directory and MUST NOT install host packages, layer RPMs,
install Chromium, run `tillandsias --init`, or configure a dedicated service
account.

#### Scenario: Fedora Silverblue install
- **WHEN** the installer runs on an ostree/rpm-ostree host
- **THEN** it installs to a user-owned bin directory, usually `~/.local/bin/tillandsias`
- **AND** it does not invoke `rpm-ostree`, `dnf`, `apt`, `podman`, or `tillandsias --init`
- **AND** it only prints a Podman install hint if Podman is missing

### Installer makes the command discoverable

When the install directory is not already on `PATH`, the installer MUST persist
an idempotent shell startup snippet for future shells and MUST print the
absolute command path for immediate use.

#### Scenario: User bin directory is missing from PATH
- **WHEN** the installer chooses `~/.local/bin` and that directory is not on `PATH`
- **THEN** it writes a marked PATH block to supported shell startup files
- **AND** a second installer run MUST NOT duplicate the block
- **AND** it prints both the absolute command and the next-shell command

### Installed runtime can initialize without checkout

The installer MUST leave the system in a state where the installed binary can
initialize from release-shipped runtime assets without requiring the Tillandsias
repository checkout.

#### Scenario: Init after curl install
- **WHEN** the installer completes successfully and Podman is available
- **THEN** running the installed binary with `--init --debug` from a non-repo directory MUST not require `TILLANDSIAS_ROOT`
- **AND** the command MUST use embedded/materialized runtime assets for image builds

### Installer verifies release assets when possible

The installer SHOULD download `SHA256SUMS` from the same GitHub Release and
verify `tillandsias-linux-x86_64` when `sha256sum` is available. A missing
checksum file SHOULD warn and continue only after the binary download succeeds.

#### Scenario: Checksum available
- **WHEN** `SHA256SUMS` contains `tillandsias-linux-x86_64`
- **THEN** the installer runs `sha256sum -c` before moving the binary into place

## Sources of Truth

- `scripts/install.sh` — curl installer implementation
- `README.md` — user-facing install command and Fedora Silverblue notes
- `openspec/specs/linux-native-portable-executable/spec.md` — release artifact shape
- `cheatsheets/runtime/linux-user-session-podman.md` — Podman runtime boundary
- `cheatsheets/runtime/user-runtime-install.md` — PATH and checkout-free install discipline

## Litmus Tests

Smallest actionable boundary:
- `grep -F 'tillandsias-linux-x86_64' scripts/install.sh`
- `bash scripts/test-install-path.sh`
- `! grep -F 'install_chromium' scripts/install.sh`
- `! grep -F 'sudo rpm-ostree install podman' scripts/install.sh >/dev/null || grep -F 'say "sudo rpm-ostree install podman"' scripts/install.sh`
