<!-- @trace spec:forge-shell-tools -->
# forge-shell-tools Specification

## Status

status: active

## Purpose
Define the live shell-tooling surface in the forge image: alternative shells, modern terminal utilities, and shell startup config that make interactive sessions useful by default.
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

> ⚠ Implementation reality (as of 2026-05-30): The lean-forge
> diet (saving ~90MB) dropped 8 of the 10 mandated terminal tools
> from the deployed image. The Containerfile docblock literally
> states: "LEAN forge: essential dev tools only. Terminal UX tools
> (mc, vim, nano, eza, bat, fd-find, fzf, htop, tree, zoxide)
> removed to save ~90MB. Users who need them can install via the
> tools overlay or microdnf." Surviving from the spec list:
> `bat` + `fd-find` (kept for git-delta + ripgrep ergonomics).
> Absent: `mc`, `vim`, `nano`, `eza`, `fzf`, `zoxide`, `htop`,
> `tree`. Note the bash/zsh `alias ll='eza -la'` references the
> absent `eza` — falls back to bash's builtin error on miss.
> Reconcile by either (a) re-adding the 8 tools to the microdnf
> install line + dropping this block + relaxing the litmus, OR
> (b) downgrading the Modern CLI tools scenario to a "tools
> overlay opt-in" contract (e.g. `tillandsias-tools` microdnf
> module) + updating the `ll` alias to fall back to `ls -la`
> when `eza` is unavailable. `litmus:forge-shell-tools-
> implementation-shape` pins the lean reality (surviving subset)
> until the architectural decision lands.

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

#### Scenario: Fish helper startup
- **WHEN** fish starts in the forge container
- **THEN** it MUST source fish-native helper functions, not the POSIX
  `shell-helpers.sh` file
- **AND** startup MUST NOT print syntax errors from bash/zsh helper syntax


## Sources of Truth

- `flake.nix` — forge image package set for shells, terminal tools, and runtime utilities
- `images/default/shell/bashrc` — bash shell startup and PATH/tool integration
- `images/default/shell/zshrc` — zsh shell startup and PATH/tool integration
- `images/default/shell/config.fish` — fish shell startup and PATH/tool integration
- `images/default/config-overlay/shell-helpers.sh` — bash/zsh helper functions
- `images/default/config-overlay/shell-helpers.fish` — fish-native helper functions
- `images/default/forge-welcome.sh` — the tool tips surfaced to interactive shells
- `cheatsheets/languages/bash.md` — bash shell reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:forge-shell-tools-shape`

Gating points:
- The forge image keeps the shell/tool package set stable
- Interactive shell configs keep the expected aliases and integrations wired
- The welcome banner keeps the shell tool tips visible to new sessions

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:forge-shell-tools" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
