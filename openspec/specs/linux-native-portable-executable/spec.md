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

### Requirement: Linux release artifact is the musl binary

The release artifact for the Linux client runtime MUST be named
`tillandsias-linux-x86_64` and MUST be the same musl-static binary installed by
`scripts/install.sh`.

#### Scenario: Curl installer uses release binary

- **WHEN** a user runs the curl installer
- **THEN** it downloads `tillandsias-linux-x86_64` from the latest GitHub Release
- **AND** installs it as `~/.local/bin/tillandsias`

### Requirement: Native tray builds may use host UI libraries

Native tray and platform integrations MAY use platform libraries when they intentionally bind to host UI, status notifier, or credential APIs.

#### Scenario: Tray build is not constrained by musl-only policy

- **WHEN** a build target includes native tray UI integration
- **THEN** the build MAY use the platform-native runtime needed by that integration

## Sources of Truth

- `cheatsheets/runtime/portable-executable-transparent-mode.md` - Portable executable model
- `cheatsheets/runtime/linux-user-session-podman.md` - Linux user-session runtime constraints
- `cheatsheets/runtime/windows-native-dev-build.md` - Cross-platform build contrast
