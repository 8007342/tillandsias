# direct-podman-calls Specification

## Purpose

Host-side operations (GitHub authentication, image builds) use direct podman and gh CLI invocations from Rust instead of bash script wrappers. Eliminates bash as a runtime dependency for host-side operations on all platforms while keeping bash scripts in the repository for manual use and documentation.

## Requirements

### Requirement: GitHub Login uses direct CLI calls instead of gh-auth-login.sh

The GitHub Login menu handler SHALL invoke `gh` and `podman` directly from Rust without extracting or executing `gh-auth-login.sh`.

#### Scenario: Host gh available
- **WHEN** the user selects "GitHub Login" from the tray menu
- **AND** the `gh` CLI is found on the host system
- **THEN** the handler SHALL open a terminal running `gh auth login --git-protocol https`
- **AND** the `GH_CONFIG_DIR` environment variable SHALL point to the managed secrets directory
- **AND** no bash script SHALL be extracted to temp or executed

#### Scenario: Host gh not available, forge container fallback
- **WHEN** the user selects "GitHub Login"
- **AND** the `gh` CLI is NOT found on the host
- **AND** the forge image exists
- **THEN** the handler SHALL open a terminal running `podman run -it --rm ...` with the forge image and `gh auth login --git-protocol https`
- **AND** security flags (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`) SHALL be applied
- **AND** D-Bus forwarding SHALL be configured if available (Linux)

#### Scenario: Git identity prompting
- **WHEN** the GitHub Login flow starts
- **THEN** the handler SHALL read existing git identity from the managed gitconfig
- **AND** prompt the user for name and email if not already set
- **AND** write the identity to the managed gitconfig via `git config --file`

#### Scenario: Windows without Git Bash
- **WHEN** running on Windows
- **AND** Git Bash is not installed or not in PATH
- **THEN** GitHub Login SHALL still work via the host `gh` CLI
- **AND** no bash.exe invocation SHALL be attempted

### Requirement: Image builds use direct podman calls on all platforms

The image build function SHALL use direct `podman build` calls on all platforms, not only on Windows.

#### Scenario: Fedora backend image build
- **WHEN** `run_build_image_script("forge")` is called on any platform
- **THEN** the function SHALL invoke `podman build --tag <tag> -f <Containerfile> <context>` directly
- **AND** no bash script SHALL be executed
- **AND** the `#[cfg(target_os = "windows")]` / `#[cfg(not(target_os = "windows"))]` branching SHALL be removed

#### Scenario: Staleness detection in Rust
- **WHEN** the image build function is called
- **THEN** it SHALL compute a hash of source files (Containerfile, image sources)
- **AND** compare against the cached hash in the build-hashes directory
- **AND** skip the build if hashes match and the image exists in podman
- **AND** the staleness logic SHALL match the behavior of `build-image.sh`

#### Scenario: Nix backend preserved for future
- **WHEN** the nix backend is requested
- **THEN** the build function MAY still use a subprocess approach
- **AND** this change does NOT require migrating the nix backend to pure Rust

### Requirement: Bash scripts remain as documentation

Host-side bash scripts SHALL remain in the repository but SHALL NOT be invoked by the binary at runtime.

#### Scenario: Scripts in repository
- **WHEN** inspecting the repository
- **THEN** `gh-auth-login.sh` SHALL exist at the project root
- **AND** `scripts/build-image.sh` SHALL exist
- **AND** both SHALL be runnable manually by developers

#### Scenario: Scripts not embedded in binary
- **WHEN** the binary is built (after both phases)
- **THEN** `gh-auth-login.sh` content SHALL NOT be included via `include_str!`
- **AND** `build-image.sh` content SHALL NOT be included via `include_str!`
- **AND** `embedded::GH_AUTH_LOGIN` and `embedded::BUILD_IMAGE` constants SHALL be removed

### Requirement: embedded::bash_path removed after full migration

The MSYS2 path conversion helper SHALL be removed once no host-side bash invocations remain.

#### Scenario: bash_path removal
- **WHEN** both Phase 1 and Phase 2 are complete
- **THEN** the `embedded::bash_path` function SHALL be removed
- **AND** no MSYS2 path conversion logic SHALL remain in the codebase

### Requirement: Security flags preserved in direct calls

All direct podman invocations SHALL apply the same security flags as the bash scripts.

#### Scenario: Container security flags
- **WHEN** `podman run` is invoked for GitHub auth
- **THEN** the arguments SHALL include `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, and `--rm`
- **AND** the flags SHALL match those in `gh-auth-login.sh`

#### Scenario: Image build security
- **WHEN** `podman build` is invoked
- **THEN** `--security-opt label=disable` SHALL be applied (for SELinux compatibility)

## Sources of Truth

- `cheatsheets/languages/rust.md` — async/await patterns, Rust CLI argument building
- `cheatsheets/utils/podman.md` — security flags, D-Bus forwarding, container networking
- `cheatsheets/utils/bash.md` — reference for original bash script behavior
