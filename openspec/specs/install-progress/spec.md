<!-- @trace spec:install-progress -->

## Status

active

## Requirements

### Curl installer is userspace-only on Linux

The curl installer MUST install the released Linux musl binary into the current
user's bin directory and MUST NOT install host packages, layer RPMs, install
Chromium, or configure a dedicated service account.

#### Scenario: Fedora Silverblue install
- **WHEN** the installer runs on an ostree/rpm-ostree host
- **THEN** it installs to `~/.local/bin/tillandsias`
- **AND** it does not invoke `rpm-ostree`, `dnf`, `apt`, `podman`, or `tillandsias --init`
- **AND** it only prints a Podman install hint if Podman is missing

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

## Litmus Tests

Smallest actionable boundary:
- `grep -F 'tillandsias-linux-x86_64' scripts/install.sh`
- `! grep -F 'install_chromium' scripts/install.sh`
- `! grep -F 'sudo rpm-ostree install podman' scripts/install.sh >/dev/null || grep -F 'say "sudo rpm-ostree install podman"' scripts/install.sh`
