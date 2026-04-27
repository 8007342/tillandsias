# forge-shell-tools Specification (Delta)

@trace spec:forge-shell-tools, spec:forge-nix-toolchain

## ADDED Requirements

### Requirement: Direnv hooks in all shell configurations

The forge shell configurations (bashrc, zshrc, config.fish) SHALL include direnv hook initialization so `.envrc` files are automatically sourced when entering a directory.

#### Scenario: Bash direnv hook is active
- **WHEN** a user opens a bash shell in the forge
- **THEN** typing `declare -F | grep direnv` shows the direnv function is loaded

#### Scenario: Zsh direnv hook is active
- **WHEN** a user opens a zsh shell in the forge
- **THEN** direnv hook is available and `.envrc` files auto-source on `cd`

#### Scenario: Fish direnv hook is active
- **WHEN** a user opens a fish shell in the forge
- **THEN** direnv hook is available and `.envrc` files auto-source on `cd`

### Requirement: Direnv integrated with nix-direnv

The direnv hook integration SHALL work with nix-direnv so `use flake` directives in `.envrc` are cached and don't re-evaluate on every `cd`.

#### Scenario: Direnv with nix-direnv is functional
- **WHEN** a project has an `.envrc` with `use flake`
- **THEN** the first `cd` into the directory evaluates the flake, and subsequent `cd` operations use the cached result

