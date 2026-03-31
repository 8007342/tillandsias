## ADDED Requirements

### Requirement: Cheatsheet documents exist for accountability-visible subsystems
Each accountability window SHALL have a corresponding cheatsheet document that explains the subsystem's behavior in plain language.

#### Scenario: Secret management cheatsheet exists
- **GIVEN** the accountability window outputs `Cheatsheet: docs/cheatsheets/secret-management.md`
- **WHEN** a developer opens that path relative to the repository root
- **THEN** the file exists and contains:
  - An overview of how secrets are stored and delivered
  - A step-by-step description of the token file lifecycle
  - A failure modes table
  - A security model section
  - Links to related specs and source files

#### Scenario: Logging levels cheatsheet exists
- **GIVEN** the `--log` help text references `docs/cheatsheets/logging-levels.md`
- **WHEN** a developer opens that path
- **THEN** the file exists and contains:
  - The six module names with descriptions
  - The log levels with usage guidelines
  - Example CLI commands
  - Links to related specs and source files

#### Scenario: Token rotation cheatsheet exists
- **GIVEN** the accountability window outputs `Cheatsheet: docs/cheatsheets/token-rotation.md`
- **WHEN** a developer opens that path
- **THEN** the file exists and contains:
  - An explanation of why short-lived tokens matter
  - How the refresh task works
  - How GIT_ASKPASS works
  - A failure modes table
  - A roadmap to GitHub App tokens
  - Links to related specs and source files

### Requirement: Cheatsheet format consistency
All cheatsheets SHALL follow a consistent format for scanability.

#### Scenario: Every cheatsheet has required sections
- **WHEN** any cheatsheet in `docs/cheatsheets/` is opened
- **THEN** it contains the following sections in order:
  1. `## Overview` — one paragraph
  2. `## How It Works` — numbered steps
  3. `## CLI Commands` — relevant commands
  4. `## Failure Modes` — table of failures, symptoms, recoveries
  5. `## Security Model` — what is protected and what is not
  6. `## Related` — specs, source files, other cheatsheets

### Requirement: Cheatsheets contain no secrets or sensitive data
Cheatsheet documents SHALL NOT contain actual tokens, keys, passwords, or user-specific paths.

#### Scenario: No real credentials in cheatsheets
- **WHEN** any cheatsheet references a token or key
- **THEN** it uses placeholder values (e.g., `gho_xxxxxxxxxxxx`, `sk-ant-...`)
- **AND** paths use generic forms (e.g., `$XDG_RUNTIME_DIR/tillandsias/tokens/`)

### Requirement: Cheatsheets are linked from accountability output
Accountability window output SHALL reference cheatsheet paths that resolve to real files.

#### Scenario: All cheatsheet references are valid
- **GIVEN** the application is built and accountability output is active
- **WHEN** the output includes a `Cheatsheet:` line
- **THEN** the referenced path exists in the repository
- **AND** the file is not empty

## MODIFIED Requirements

None (documentation only, no code behavior changes).
