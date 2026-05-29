# linux-native-portable-executable Specification

@trace spec:linux-native-portable-executable

## Status

active

## Requirements

### Requirement: Headless Linux launcher is portable across common distros

The default headless Tillandsias launcher for Linux MUST be buildable as a self-contained executable suitable for systems that do not have the project workspace or Rust toolchain installed.

#### Scenario: Portable install skips host development configuration

- **WHEN** the build runs in install/portable mode
- **THEN** it MUST NOT require host development registry configuration
- **AND** runtime prerequisites MUST be reported as user-facing setup requirements rather than hidden build-time coupling

### Requirement: Linux binary carries runtime image contexts

The Linux release binary MUST carry the runtime image contexts and helper scripts needed to initialize the user runtime without a Tillandsias source checkout. The binary MAY materialize those assets under `$XDG_DATA_HOME/tillandsias/runtime/<VERSION>` or the equivalent user data fallback before invoking Podman.

#### Scenario: Installed binary initializes outside checkout

- **WHEN** the curl-installed binary runs `--init --debug` from a directory that is not a Tillandsias checkout
- **THEN** it MUST find or materialize the release-shipped runtime assets
- **AND** it MUST NOT require `TILLANDSIAS_ROOT`, Rust, Cargo, Nix, or toolbox

### Requirement: Linux release artifact is the musl binary

The release artifact for the Linux client runtime MUST be named
`tillandsias-linux-x86_64` and MUST be the same musl-static binary installed by
`scripts/install.sh`.

The binary MUST be built for a `*-unknown-linux-musl` target and statically
linked (no dynamic libc dependency). This is a deliberate **portability
requirement**, not an incidental build choice: a glibc-dynamic binary couples
to the host's glibc version and would fail or misbehave across the range of
distros and glibc vintages users run. musl-static linkage makes the single
published artifact run unmodified on any modern x86_64 Linux (and aarch64 for
the in-VM agent), which is the whole point of a checkout-free, toolchain-free
portable executable. The same requirement applies to the in-VM headless agent
assets (`tillandsias-headless-<arch>-unknown-linux-musl`), which are
curl-installed into the (potentially different-libc) VM rootfs at first boot.
The nix build surfaces this as a hard constraint: a non-musl-static Linux
release target is a portability regression and MUST be rejected.

#### Scenario: Curl installer uses release binary

- **WHEN** a user runs the curl installer
- **THEN** it downloads `tillandsias-linux-x86_64` from the latest GitHub Release
- **AND** installs it as `tillandsias` in a safe current-user bin directory, usually `~/.local/bin/tillandsias`

#### Scenario: Release build target is musl-static

- **WHEN** the Linux release artifact (or an in-VM headless agent asset) is built
- **THEN** the cargo target MUST be `*-unknown-linux-musl`
- **AND** the resulting binary MUST be statically linked (`file(1)` reports "statically linked")
- **AND** a glibc-dynamic or otherwise host-coupled Linux release binary MUST NOT be published

### Requirement: Native tray builds may use host UI libraries

Native tray and platform integrations MAY use platform libraries when they intentionally bind to host UI, status notifier, or credential APIs.

#### Scenario: Tray build is not constrained by musl-only policy

- **WHEN** a build target includes native tray UI integration
- **THEN** the build MAY use the platform-native runtime needed by that integration

## Sources of Truth

- `cheatsheets/runtime/portable-executable-transparent-mode.md` - Portable executable model
- `cheatsheets/runtime/linux-user-session-podman.md` - Linux user-session runtime constraints
- `cheatsheets/runtime/windows-native-dev-build.md` - Cross-platform build contrast
- `cheatsheets/runtime/user-runtime-install.md` - Checkout-free user runtime contract
