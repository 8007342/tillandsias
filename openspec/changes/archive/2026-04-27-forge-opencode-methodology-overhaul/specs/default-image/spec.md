# default-image Delta Specification

@trace spec:default-image

## ADDED Requirements

### Requirement: OpenCode config includes 4 new instruction files
The `images/default/config-overlay/opencode/config.json` instructions list SHALL expand from 3 to 5 files to include methodology index and 4 action-first sub-files.

#### Scenario: config.json lists all 5 instruction files in order
- **WHEN** the default forge image is built
- **THEN** `config.json` instructions array includes these paths in order:
  - `/home/forge/.config-overlay/opencode/instructions/methodology.md`
  - `/home/forge/.config-overlay/opencode/instructions/forge-discovery.md`
  - `/home/forge/.config-overlay/opencode/instructions/cache-discipline.md`
  - `/home/forge/.config-overlay/opencode/instructions/nix-first.md`
  - `/home/forge/.config-overlay/opencode/instructions/openspec-workflow.md`
  - (plus existing flutter.md, model-routing.md, web-services.md as additional references)

#### Scenario: Agent reads methodology.md first
- **WHEN** OpenCode loads config.json
- **THEN** the first instruction file is methodology.md
- **THEN** methodology.md directs the agent to the 4 sub-files for specific workflows

### Requirement: config-overlay installs 4 new instruction files
The `images/default/config-overlay/opencode/instructions/` directory SHALL contain 4 new markdown files, each under 200 lines and action-first in structure.

#### Scenario: forge-discovery.md exists
- **WHEN** the image is built
- **THEN** `/home/forge/.config-overlay/opencode/instructions/forge-discovery.md` exists and is readable
- **THEN** the file contains inventory, cheatsheet discovery, and openspec workflow guidance

#### Scenario: cache-discipline.md exists
- **WHEN** the image is built
- **THEN** `/home/forge/.config-overlay/opencode/instructions/cache-discipline.md` exists and is readable
- **THEN** the file contains the four-category path model and per-language env vars

#### Scenario: nix-first.md exists
- **WHEN** the image is built
- **THEN** `/home/forge/.config-overlay/opencode/instructions/nix-first.md` exists and is readable
- **THEN** the file contains Nix flake guidance for new projects

#### Scenario: openspec-workflow.md exists
- **WHEN** the image is built
- **THEN** `/home/forge/.config-overlay/opencode/instructions/openspec-workflow.md` exists and is readable
- **THEN** the file contains step-by-step workflow with proposal, design, specs, tasks, archive

### Requirement: methodology.md becomes an index
The `images/default/config-overlay/opencode/instructions/methodology.md` file SHALL be rewritten as a ~15-line index that points agents to the 4 sub-files, replacing the current 36-line generic principles document.

#### Scenario: methodology.md is concise and actionable
- **WHEN** agent reads methodology.md
- **THEN** the file is under 20 lines
- **THEN** each line describes when to read which sub-file

#### Scenario: methodology.md maintains core principles section
- **WHEN** agent needs a reminder of the five core principles (monotonic convergence, CRDT, spec-is-truth, ephemeral-first, privacy-first)
- **THEN** methodology.md includes a short "Core Principles" section linking to the deeper guidance in sub-files
