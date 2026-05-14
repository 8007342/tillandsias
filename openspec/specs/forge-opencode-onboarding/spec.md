# forge-opencode-onboarding Specification

## Status

status: active

## Purpose
The OpenCode onboarding bundle SHALL define the live launch-time contract for newly attached forge sessions: discovery, modular instructions, OpenSpec bootstrap, and the synthetic `/startup` prompt.

## Requirements
### Requirement: First-turn environment discovery
The onboarding bundle SHALL surface discovery guidance before work begins in a freshly attached forge container.

#### Scenario: Agent discovers available tools
- **WHEN** OpenCode starts in a new forge container
- **THEN** the agent MUST run `tillandsias-inventory` to list pre-installed tools and their versions
- **THEN** the agent MUST read `$TILLANDSIAS_CHEATSHEETS/INDEX.md` to understand what references are available

#### Scenario: Agent avoids assuming tool absence
- **WHEN** the agent is unsure if a tool is installed
- **THEN** the agent MUST run `which <tool>` or check inventory instead of guessing

### Requirement: Modularized instruction files
The OpenCode `config.json` instruction list SHALL keep the first-turn bundle modular: `methodology.md` as the index plus `forge-discovery.md`, `cache-discipline.md`, `nix-first.md`, and `openspec-workflow.md` as the first five stable files. Additional specialized instruction files MAY follow after those five.

#### Scenario: Agent receives methodology.md as first-turn context
- **WHEN** OpenCode loads config.json
- **THEN** instructions[0] MUST be `/home/forge/.config-overlay/opencode/instructions/methodology.md`
- **THEN** methodology.md MUST index the other four onboarding files

#### Scenario: Agent reads focused sub-file for cache discipline
- **WHEN** the agent needs to understand where to write build artifacts
- **THEN** the agent MUST read `/home/forge/.config-overlay/opencode/instructions/cache-discipline.md`

#### Scenario: Agent references discovery workflow
- **WHEN** the agent starts work in a new project
- **THEN** the agent MUST consult `/home/forge/.config-overlay/opencode/instructions/forge-discovery.md` for first-turn steps

### Requirement: OpenCode bootstrap seeds /startup and OpenSpec init
The launcher SHALL apply the OpenCode config overlay, run `openspec init --tools opencode` for the active project, and seed a synthetic `/startup` prompt before handing control to OpenCode.

#### Scenario: Launcher initializes the project on attach
- **WHEN** `entrypoint-forge-opencode.sh` starts a forge session
- **THEN** it MUST apply the OpenCode config overlay
- **THEN** it MUST run `openspec init --tools opencode` when a project is present
- **THEN** it MUST write `run /startup` to the OpenCode init prompt path

#### Scenario: Launcher keeps the startup prompt deterministic
- **WHEN** `TILLANDSIAS_OPENCODE_PROMPT` is unset
- **THEN** the launcher MUST still write `run /startup`
- **WHEN** the prompt file already exists
- **THEN** a restart MUST remain deterministic and keep the startup bootstrap path idempotent

## Sources of Truth

- `images/default/config-overlay/opencode/config.json` — bundled instruction list and OpenCode model/config defaults
- `images/default/config-overlay/opencode/instructions/methodology.md` — modular onboarding index for the first-turn instruction bundle
- `images/default/config-overlay/opencode/instructions/forge-discovery.md` — first-turn discovery guidance
- `images/default/entrypoint-forge-opencode.sh` — config overlay application, OpenSpec init, and `/startup` bootstrap
- `cheatsheets/agents/opencode.md` — OpenCode workflow and CLI usage patterns
- `cheatsheets/agents/openspec.md` — OpenSpec proposal/design/spec/task/archive lifecycle
- `cheatsheets/runtime/forge-container.md` — forge container runtime expectations

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:forge-opencode-onboarding-shape`

Gating points:
- Onboarding is deterministic and reproducible across restarts
- The config overlay and startup bootstrap remain visible to the agent
- The onboarding instruction bundle keeps the first five files stable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:forge-opencode-onboarding" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
