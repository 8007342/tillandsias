<!-- @trace spec:forge-shell-tools -->
# forge-shell-tools Specification

## Status

status: active

## Purpose
TBD - created by archiving change forge-shell-tools. Update Purpose after archive.
## Requirements
### Requirement: Alternative shells available
The forge image MUST include fish and zsh, startable by typing `fish` or `zsh` from any shell.

#### Scenario: Start fish
- **WHEN** a user types `fish` inside the forge container
- **THEN** the fish shell MUST start with a configured prompt and PATH

#### Scenario: Start zsh
- **WHEN** a user types `zsh` inside the forge container
- **THEN** the zsh shell MUST start with autocompletion and a configured prompt

### Requirement: Terminal tools installed
The forge image MUST include a curated set of terminal tools for file management, editing, and modern CLI workflows.

#### Scenario: File manager
- **WHEN** a user types `mc` inside the forge container
- **THEN** Midnight Commander MUST start for visual file browsing

#### Scenario: Editors
- **WHEN** a user types `vim` or `nano` inside the forge container
- **THEN** the respective editor MUST open

#### Scenario: Modern CLI tools
- **WHEN** a user types `eza`, `bat`, `fd`, `fzf`, `zoxide`, `htop`, or `tree`
- **THEN** the respective tool MUST run

### Requirement: Shell configurations
The forge image MUST include sensible default configs for bash, fish, and zsh with colored output, useful aliases, and modern tool integration.

#### Scenario: Bash prompt
- **WHEN** bash starts in the forge container
- **THEN** the prompt MUST show the current directory with color

#### Scenario: Aliases available
- **WHEN** a user types `ll` in any shell
- **THEN** a detailed directory listing MUST be displayed (using eza if available, ls -la otherwise)

#### Scenario: zoxide integration
- **WHEN** zoxide is installed and the shell config is loaded
- **THEN** `z` command MUST be available for smart directory navigation


## Sources of Truth

- `cheatsheets/languages/bash.md` — Bash reference and patterns
- `cheatsheets/runtime/cmd.md` — Cmd reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Shell tools are isolated; no host tools leak into container
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:forge-shell-tools" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
