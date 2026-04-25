# default-image Specification

## Purpose
TBD - created by archiving change attach-here-mvp. Update Purpose after archive.
## Requirements
### Requirement: Fedora Minimal base image with dev tools
The default container image SHALL be based on Fedora Minimal and include OpenCode, OpenSpec CLI, Nix, and essential development tools.

#### Scenario: Image contains OpenCode
- **WHEN** the container starts
- **THEN** `opencode` is available in PATH and executable

#### Scenario: Image contains OpenSpec
- **WHEN** the container starts
- **THEN** `openspec` is available in PATH (installed or deferred to first run)

#### Scenario: Image contains Nix
- **WHEN** the container starts
- **THEN** `nix` is available for reproducible builds with flakes enabled

#### Scenario: Image contains git and GitHub CLI
- **WHEN** the container starts
- **THEN** `git` and `gh` are available in PATH

### Requirement: Non-root user with UID 1000
The container SHALL run as user `forge` (UID 1000) to match host user UID via `--userns=keep-id`.

#### Scenario: Volume permissions
- **WHEN** the container mounts a host directory
- **THEN** files created inside the container are owned by the host user (UID 1000)

### Requirement: Entrypoint launches OpenCode
The container entrypoint SHALL bootstrap the environment and launch OpenCode as the foreground process.

#### Scenario: First run bootstrap
- **WHEN** the container starts for the first time
- **THEN** cache directories are created, OpenSpec is installed if deferred, and OpenCode launches

#### Scenario: Subsequent runs
- **WHEN** the container starts with existing cache
- **THEN** bootstrap is skipped and OpenCode launches immediately

### Requirement: Declarative image definition via flake.nix
The default forge image SHALL be defined declaratively in flake.nix using Nix's dockerTools, replacing the Containerfile as the primary build path.

#### Scenario: Build forge image
- **WHEN** `scripts/build-image.sh forge` is run
- **THEN** the image is built via `nix build .#forge-image` inside the builder toolbox

#### Scenario: Build web image
- **WHEN** `scripts/build-image.sh web` is run
- **THEN** the image is built via `nix build .#web-image` inside the builder toolbox

### Requirement: Forge image ships an OpenCode Web entrypoint

The default forge image SHALL include `/usr/local/bin/entrypoint-forge-opencode-web.sh`, installed with executable permissions, alongside the existing OpenCode and Claude entrypoints.

#### Scenario: Script is present and executable
- **WHEN** the built forge image is inspected
- **THEN** the file `/usr/local/bin/entrypoint-forge-opencode-web.sh` exists and is executable
- **AND** the file is owned consistently with the other entrypoints

### Requirement: OpenCode Web entrypoint runs opencode serve

The web entrypoint SHALL terminate by `exec`-ing `opencode serve --hostname 0.0.0.0 --port 4096`, binding inside the container only, after the standard setup (CA trust, git clone, OpenSpec init, OpenCode install).

#### Scenario: Final exec targets opencode serve
- **WHEN** a web-mode container starts to steady state
- **THEN** the container's PID 1 is an `opencode serve` process listening on `0.0.0.0:4096` inside the container's netns
- **AND** no terminal UI is launched

### Requirement: Default opencode model is a tool-capable Zen provider

The bundled `images/default/config-overlay/opencode/config.json` SHALL
set `model` to a tool-capable Zen model (default:
`opencode/big-pickle`). `small_model` SHALL be clamped at runtime to a
model that is **image-baked** in the inference container — either
`ollama/qwen2.5:0.5b` (T0, always baked) or `ollama/llama3.2:3b` (T1,
always baked) — regardless of detected GPU tier.

Claiming a larger tier-tagged model in `small_model` when that model
isn't in the inference cache leaves opencode's sub-tasks pointing at a
model that doesn't exist. Squid's SSL-bump can't reliably pull the big
ollama manifests at runtime (see project memory `project_squid_ollama_eof`),
so tier-upgrades past T1 are a user-driven opt-in via
`--model ollama/<name>` after they've manually pulled what they want.

The `ollama` provider SHALL remain fully enumerated in the config so
users can select any enumerated model on demand.

#### Scenario: Ultra-tier host uses the baked T1 model for analysis
- **WHEN** the host has a GPU classified as Ultra (>=12GB VRAM) and the
  tray patches the config overlay
- **THEN** `small_model` SHALL be `ollama/llama3.2:3b` (baked T1), NOT
  `ollama/qwen2.5:14b` or any other non-baked model
- **AND** opencode sub-tasks SHALL succeed on a freshly-attached project
  with no manual model pulls

#### Scenario: First `opencode run` from a fresh attach uses a Zen model
- **WHEN** a forge container is freshly attached to a project
- **AND** the user runs `opencode run "<prompt>"` with no `--model`
- **THEN** the request SHALL go to `opencode/big-pickle` (or the
  configured Zen default)
- **AND** the run SHALL be capable of tool calling (write_file,
  bash_exec, etc.)

#### Scenario: User opts into a larger model
- **WHEN** the user manually runs `ollama pull qwen2.5:14b` inside the
  inference container
- **AND** later runs `opencode run --model ollama/qwen2.5:14b
  "<prompt>"`
- **THEN** the request SHALL route to that model
- **AND** the clamp SHALL NOT interfere — the clamp only affects the
  default `small_model`, not explicit `--model` overrides

### Requirement: Cooperative split documented in agent instructions

The bundled instructions surfaced to opencode SHALL include guidance
that ollama models are for analysis subtasks (no tool calling required)
and Zen models are for tool-driven work. Future expansion to give
ollama models tool access SHALL update this guidance and the spec
together.

#### Scenario: Agent picks the right model for the work
- **WHEN** the agent has a sub-task that's pure analysis (summarize,
  classify, extract)
- **THEN** the instructions SHALL allow it to delegate to
  `ollama/llama3.2:3b` or another local model
- **WHEN** the agent has a tool-driven task (write file, run command,
  commit)
- **THEN** the instructions SHALL keep the work on the Zen tool-caller

