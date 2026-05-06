# Specification: portable-linux-executable

@trace spec:portable-linux-executable

## ADDED Requirements

### Requirement: musl-static build target
The tillandsias binary SHALL be built with `x86_64-unknown-linux-musl` target, producing a statically-linked executable with no libc dependency.

#### Scenario: Build succeeds for musl target
- **WHEN** `cargo build --release --target x86_64-unknown-linux-musl` is run
- **THEN** binary is produced at target/x86_64-unknown-linux-musl/release/tillandsias

#### Scenario: Binary runs on multiple distros
- **WHEN** musl-static binary is copied to Ubuntu, Arch, or Fedora system
- **THEN** binary executes without requiring libglibc or other system libraries to be installed

### Requirement: No system library dependencies
The tillandsias executable SHALL have zero runtime dependencies on system libc or other standard libraries.

#### Scenario: Binary is self-contained
- **WHEN** `ldd ./tillandsias` is run on the musl binary
- **THEN** output shows "not a dynamic executable" or "statically linked"

