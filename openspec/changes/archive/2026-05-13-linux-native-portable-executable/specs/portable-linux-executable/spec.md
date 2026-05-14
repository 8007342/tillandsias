# Specification: portable-linux-executable

@trace spec:portable-linux-executable

## ADDED Requirements

### Requirement: portable headless launcher build target
The default tillandsias headless launcher SHALL be built with `x86_64-unknown-linux-musl` target, producing a statically-linked executable with no libc dependency while the launcher remains pure Rust plus subprocess/container orchestration.

Musl is not a requirement for native tray, GTK, keyring, browser, or other host-library integrations. Those surfaces SHALL use the platform-native runtime when they need system libraries, including Fedora/glibc on Linux.

#### Scenario: Build succeeds for musl target
- **WHEN** `cargo build --release --target x86_64-unknown-linux-musl` is run
- **THEN** binary is produced at target/x86_64-unknown-linux-musl/release/tillandsias

#### Scenario: Headless launcher runs on multiple distros
- **WHEN** the musl-static headless launcher is copied to Ubuntu, Arch, or Fedora system
- **THEN** the launcher executes without requiring libglibc or other system libraries to be installed

### Requirement: No system library dependencies for default headless launcher
The default headless launcher executable SHALL have zero runtime dependencies on system libc or other standard libraries.

Native tray builds and platform wrappers are excluded from this requirement when they intentionally bind to platform UI or credential APIs.

#### Scenario: Binary is self-contained
- **WHEN** `ldd ./tillandsias` is run on the musl binary
- **THEN** output shows "not a dynamic executable" or "statically linked"
