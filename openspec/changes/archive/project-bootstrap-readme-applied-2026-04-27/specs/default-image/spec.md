# default-image — project-bootstrap-readme delta

@trace spec:default-image, spec:project-bootstrap-readme

This delta extends `openspec/specs/default-image/spec.md` with the bake artifacts and OpenCode entrypoint shim for the project-bootstrap-readme capability. All existing default-image requirements remain unchanged.

## ADDED Requirements

### Requirement: Forge image bakes the four startup skills

The forge image SHALL include four OpenCode skill markdown files under `~/.config-overlay/opencode/agent/` (mounted into the OpenCode user config at entrypoint time):

- `startup.md` — entrypoint skill, reads project state and routes
- `bootstrap-readme-and-project.md` — empty-project welcome flow
- `bootstrap-readme.md` — non-empty / bad-README regen flow
- `status.md` — non-empty / good-README snapshot flow

Each skill file SHALL be world-readable (mode 0644), owned by `root:root` so the forge user (UID 1000) can read but not modify. Source files in the repository live under `images/default/config-overlay/opencode/agent/` and are baked into the image during the existing `COPY` stage.

#### Scenario: Four skill files present in the image

- **WHEN** the forge image is built and inspected
- **THEN** `~/.config-overlay/opencode/agent/startup.md`, `bootstrap-readme-and-project.md`, `bootstrap-readme.md`, and `status.md` SHALL exist
- **AND** each SHALL be mode 0644
- **AND** each SHALL contain valid OpenCode skill frontmatter and body

#### Scenario: Forge user cannot mutate skill files

- **WHEN** the forge user (UID 1000) runs `touch ~/.config-overlay/opencode/agent/startup.md`
- **THEN** the call SHALL fail with EACCES — skill files are image-state, not user-state

### Requirement: Forge image bakes the README dispatcher and validator

The forge image SHALL include `/usr/local/bin/regenerate-readme.sh` (the per-language summarizer dispatcher) and `/usr/local/bin/check-readme-discipline.sh` (the structural validator). Source files live under `images/default/scripts/` in the repository. Both SHALL be executable (mode 0755).

#### Scenario: Dispatcher and validator present and executable

- **WHEN** the forge image is built and inspected
- **THEN** `/usr/local/bin/regenerate-readme.sh` and `/usr/local/bin/check-readme-discipline.sh` SHALL exist
- **AND** both SHALL have mode 0755

### Requirement: Forge image bakes a welcome cheatsheet category

The forge image SHALL include a new `welcome/` subdirectory under `/opt/cheatsheets-image/` (the image-baked canonical) carrying at minimum:

- `sample-prompts.md` — the curated sample prompts cheatsheet read by `/bootstrap-readme-and-project`
- `readme-discipline.md` — the agent-facing reference for the README structural contract

The directory SHALL participate in `populate_hot_paths()` exactly like the existing seven category directories (`runtime/`, `languages/`, `utils/`, `build/`, `web/`, `test/`, `agents/`) — no special-casing.

#### Scenario: welcome/ category appears in INDEX.md

- **WHEN** the forge image is built and `cat /opt/cheatsheets/INDEX.md` runs inside the container
- **THEN** the output SHALL list a `## welcome` section with at minimum two cheatsheet entries

### Requirement: OpenCode entrypoint shim writes synthetic first prompt

`images/default/entrypoint-forge-opencode.sh` SHALL gain a small block (idempotent, runs once per container start) that writes a synthetic first user message to a known path before `exec`-ing OpenCode. The path SHALL match the OpenCode auto-prompt convention (whatever path OpenCode reads on first message; suggested `~/.config/opencode/auto-prompt.txt` until OpenCode formalises one). The synthetic prompt SHALL be the literal string `run /startup`.

The shim SHALL NOT touch other entrypoints (`entrypoint-forge-claude.sh`, `entrypoint-forge-opencode-web.sh`, `entrypoint-terminal.sh`).

#### Scenario: Synthetic prompt is written before OpenCode launches

- **WHEN** `entrypoint-forge-opencode.sh` runs (first container start)
- **THEN** the auto-prompt path SHALL be created with content `run /startup`
- **AND** OpenCode SHALL be exec'd AFTER the file is written

#### Scenario: Shim is idempotent across restarts

- **WHEN** the container restarts and the entrypoint runs again
- **THEN** the auto-prompt file is overwritten (not appended) so the agent always sees `run /startup` as the first prompt of every session

#### Scenario: Other entrypoints are unaffected

- **WHEN** `entrypoint-forge-claude.sh` or `entrypoint-terminal.sh` runs
- **THEN** no auto-prompt file SHALL be written
- **AND** Claude / the terminal SHALL behave identically to pre-change

## Sources of Truth

- `cheatsheets/runtime/agent-startup-skills.md` (planned) — agent-facing reference for the four skills baked here
- `cheatsheets/welcome/readme-discipline.md` (planned) — structural contract this image surfaces
- `cheatsheets/welcome/sample-prompts.md` (planned) — sample prompts read by `/bootstrap-readme-and-project`
- `openspec/changes/project-bootstrap-readme/design.md` — Decisions 1, 2, 5, 9, and 10 motivate these bake artifacts
