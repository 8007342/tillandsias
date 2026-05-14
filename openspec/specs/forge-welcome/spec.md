<!-- @trace spec:forge-welcome -->
# forge-welcome Specification

## Status

status: active

## Purpose
Define the interactive terminal welcome banner and its once-per-session startup gating so new forge sessions expose project context, OS context, and discovery tips without repeating themselves.
## Requirements
### Requirement: Welcome message on terminal launch
The forge container MUST display a colorful welcome message when an interactive terminal session starts.

#### Scenario: Welcome message content
- **WHEN** a user opens a terminal via the tray menu or `--bash` CLI flag
- **THEN** the welcome message MUST display: project name (bold cyan), forge OS + host OS versions (human-readable), mount points with access colors, project path, and a rotating tip

#### Scenario: Mount point color coding
- **WHEN** the welcome message lists mount points
- **THEN** read-write mounts MUST be shown in green, read-only mounts in red, and encrypted-source mounts in blue

#### Scenario: Rotating tips
- **WHEN** the welcome message is displayed
- **THEN** a randomly selected tip from a pool of ~20 beginner-friendly one-liners MUST be shown as the final line, with command keywords highlighted in bold

#### Scenario: Human-readable OS versions
- **WHEN** the welcome message shows OS information
- **THEN** it MUST display friendly names like "Fedora 43 (Minimal)" and "Fedora Silverblue 43", not raw kernel version strings

### Requirement: Fish as default interactive shell
The Terminal menu item and `--bash` CLI flag MUST launch the fish shell instead of bash.

#### Scenario: Terminal from tray
- **WHEN** the user clicks a project's Terminal (Ground) menu item
- **THEN** the container MUST start with fish as the entrypoint, landing in the project directory

#### Scenario: CLI --bash flag
- **WHEN** the user runs `tillandsias ../project/ --bash`
- **THEN** the container MUST start with fish as the entrypoint, landing in the project directory

#### Scenario: Switch to bash
- **WHEN** the user types `bash` inside the fish shell
- **THEN** bash MUST start normally (fish is not mandatory)


## Sources of Truth

- `images/default/forge-welcome.sh` — welcome banner layout, rotating tips, and localization
- `images/default/entrypoint-terminal.sh` — terminal entrypoint that triggers the banner
- `images/default/shell/bashrc` — bash startup guard for the banner
- `images/default/shell/zshrc` — zsh startup guard for the banner
- `images/default/shell/config.fish` — fish startup guard for the banner
- `cheatsheets/runtime/forge-container.md` — forge runtime boundaries and shell expectations
- `cheatsheets/runtime/agent-startup-skills.md` — launch-time onboarding and startup routing

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:forge-welcome-shape`

Gating points:
- The welcome banner stays visible in the launch path
- The banner remains gated to once per session
- The tip pool and project/OS scaffolding remain present

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:forge-welcome" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
