# Capability: forge-nix-toolchain

**Status**: NEW

@trace spec:forge-nix-toolchain

## Summary

Nix + direnv + nix-direnv baked into the forge image, with experimental features enabled and shell hooks configured so `.envrc` files auto-activate on directory change.

## ADDED Requirements

### Requirement: Nix installed in single-user mode

The forge image SHALL include nix installed via the official installer in single-user mode. The nix binary SHALL be available on PATH and `nix --version` SHALL return a valid version string.

#### Scenario: Nix binary is available
- **WHEN** a container starts with the updated forge image
- **THEN** `which nix` returns `/nix/bin/nix` or similar
- **AND** `nix --version` outputs a version string (e.g., `nix (Nix) 2.18.0`)

#### Scenario: Nix can be invoked
- **WHEN** a user runs `nix flake --help` inside the forge
- **THEN** the command succeeds and outputs flake documentation

### Requirement: Experimental features enabled

The forge image SHALL configure `/etc/nix/nix.conf` to enable nix-command and flakes experimental features. The configuration SHALL be read by all nix invocations.

#### Scenario: Experimental features are enabled
- **WHEN** a user runs `nix --version` and `nix flake show <flake-path>`
- **THEN** both commands succeed without warnings about experimental features being disabled

#### Scenario: Nix configuration is set system-wide
- **WHEN** a user checks `cat /etc/nix/nix.conf`
- **THEN** the output includes `experimental-features = nix-command flakes` (or similar)

### Requirement: Direnv installed and hooks configured

The forge image SHALL include direnv. Shell configurations (bashrc, zshrc, config.fish) SHALL include direnv hooks so `.envrc` files are automatically sourced on directory change.

#### Scenario: Direnv is available
- **WHEN** a user runs `which direnv`
- **THEN** the command returns a valid direnv binary path

#### Scenario: Bash direnv hook is installed
- **WHEN** a user opens a bash shell in the forge
- **THEN** the environment includes direnv hook (verifiable via `declare -F | grep direnv`)

#### Scenario: Zsh direnv hook is installed
- **WHEN** a user opens a zsh shell in the forge
- **THEN** the environment includes direnv hook

#### Scenario: Fish direnv hook is installed
- **WHEN** a user opens a fish shell in the forge
- **THEN** the environment includes direnv hook

### Requirement: Nix-direnv installed for performance

The forge image SHALL include nix-direnv to cache nix environment evaluations. When a `.envrc` file invokes `use flake`, nix-direnv SHALL cache the result and avoid re-evaluating on repeated `cd` into the same directory.

#### Scenario: Nix-direnv is available
- **WHEN** a user runs `nix-direnv --version`
- **THEN** the command returns a valid version string

#### Scenario: Cached evaluation improves performance
- **WHEN** a user repeatedly `cd` into a directory with a stable `flake.nix`
- **THEN** subsequent `cd` operations complete faster than the first (< 1 second vs. 5-10 seconds)

### Requirement: NIX_CONFIG and NIX_PATH set in entrypoint

The forge entrypoint SHALL export `NIX_CONFIG=/etc/nix/nix.conf` and `NIX_PATH=nixpkgs=flake:nixpkgs` so nix commands can access the system configuration and default nixpkgs without per-project setup.

#### Scenario: NIX_CONFIG is set
- **WHEN** a user runs `echo $NIX_CONFIG` in the forge
- **THEN** the output is `/etc/nix/nix.conf`

#### Scenario: NIX_PATH is set
- **WHEN** a user runs `echo $NIX_PATH`
- **THEN** the output includes `nixpkgs=flake:nixpkgs`

### Requirement: /nix/store mount is writable by forge user

The forge /nix/store mount (inherited from forge-cache-architecture) SHALL allow the forge user (uid 1000) to write build outputs. When `nix build` runs, artifacts SHALL be stored in /nix/store with correct ownership.

#### Scenario: /nix/store exists and is accessible
- **WHEN** a user lists `/nix/store` in the forge
- **THEN** the directory exists and is readable

#### Scenario: Nix builds can write to /nix/store
- **WHEN** a user runs a simple nix build (e.g., `nix build` in a minimal flake)
- **THEN** the build succeeds and outputs appear in /nix/store

## Sources of Truth

- `cheatsheets/build/nix-flake-basics.md` — nix flake authoring and direnv usage patterns
- `cheatsheets/runtime/forge-shared-cache-via-nix.md` — architecture and rationale for shared /nix/store mount
