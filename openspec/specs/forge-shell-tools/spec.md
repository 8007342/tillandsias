<!-- @trace spec:forge-shell-tools -->
# forge-shell-tools Specification

## Status

status: active

## Purpose
TBD - created by archiving change forge-shell-tools. Update Purpose after archive.
## Requirements
### Requirement: Alternative shells available
The forge image SHALL include fish and zsh, startable by typing `fish` or `zsh` from any shell.

#### Scenario: Start fish
- **WHEN** a user types `fish` inside the forge container
- **THEN** the fish shell starts with a configured prompt and PATH

#### Scenario: Start zsh
- **WHEN** a user types `zsh` inside the forge container
- **THEN** the zsh shell starts with autocompletion and a configured prompt

### Requirement: Terminal tools installed
The forge image SHALL include a curated set of terminal tools for file management, editing, and modern CLI workflows.

#### Scenario: File manager
- **WHEN** a user types `mc` inside the forge container
- **THEN** Midnight Commander starts for visual file browsing

#### Scenario: Editors
- **WHEN** a user types `vim` or `nano` inside the forge container
- **THEN** the respective editor opens

#### Scenario: Modern CLI tools
- **WHEN** a user types `eza`, `bat`, `fd`, `fzf`, `zoxide`, `htop`, or `tree`
- **THEN** the respective tool runs

### Requirement: Shell configurations
The forge image SHALL include sensible default configs for bash, fish, and zsh with colored output, useful aliases, and modern tool integration.

#### Scenario: Bash prompt
- **WHEN** bash starts in the forge container
- **THEN** the prompt shows the current directory with color

#### Scenario: Aliases available
- **WHEN** a user types `ll` in any shell
- **THEN** a detailed directory listing is displayed (using eza if available, ls -la otherwise)

#### Scenario: zoxide integration
- **WHEN** zoxide is installed and the shell config is loaded
- **THEN** `z` command is available for smart directory navigation


## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:forge-shell-tools" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
