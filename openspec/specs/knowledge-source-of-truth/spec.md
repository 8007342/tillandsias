<!-- @trace spec:knowledge-source-of-truth -->
## Status

status: active

## ADDED Requirements

### Requirement: Knowledge directory structure
The project SHALL maintain a `knowledge/` directory at the repository root containing project-agnostic technology cheatsheets organized by domain.

#### Scenario: Directory layout
- **WHEN** a developer or agent inspects the `knowledge/` directory
- **THEN** it SHALL contain: `index.xml`, `manifest.toml`, `README.md`, and a `cheatsheets/` subdirectory
- **AND** `cheatsheets/` SHALL contain domain subdirectories: `infra/`, `lang/`, `frameworks/`, `packaging/`, `formats/`, `ci/`

### Requirement: Cheatsheet format
Each cheatsheet SHALL be a Markdown file with YAML frontmatter containing: `id`, `title`, `category`, `tags`, `upstream`, `version_pinned`, `last_verified`, and `authority`.

#### Scenario: Cheatsheet structure
- **WHEN** an agent reads a cheatsheet file
- **THEN** the file SHALL have YAML frontmatter with all required fields
- **AND** the Markdown body SHALL contain focused, actionable reference content under 4K tokens
- **AND** the `authority` field SHALL be one of: `official`, `community`, `derived`

#### Scenario: One topic per file
- **WHEN** a new cheatsheet is created
- **THEN** it SHALL cover exactly one focused topic (e.g., `podman-rootless.md` not `podman.md`)
- **AND** an agent SHALL be able to load the entire file in a single context read

### Requirement: XML collection index
The `knowledge/index.xml` file SHALL provide a structured index of all cheatsheets organized by category and cross-referenced by tags.

#### Scenario: Category querying
- **WHEN** an agent needs all cheatsheets in a domain (e.g., `infra/containers`)
- **THEN** the index.xml SHALL list all cheatsheets under that category with file path references

#### Scenario: Tag querying
- **WHEN** an agent needs cheatsheets related to a concept (e.g., `security`)
- **THEN** the index.xml SHALL list all cheatsheet IDs tagged with that concept

### Requirement: Version tracking and freshness
The `knowledge/manifest.toml` file SHALL track the upstream source, pinned version, and last verification date for each cheatsheet.

#### Scenario: Staleness detection
- **WHEN** a cheatsheet's `last_verified` date is older than 6 months
- **THEN** `scripts/verify-freshness.sh` SHALL flag it as potentially stale

### Requirement: Project agnosticism
Knowledge cheatsheets SHALL contain NO references to Tillandsias, its codebase, its architecture, or any project-specific decisions.

#### Scenario: Content independence
- **WHEN** a cheatsheet is written or updated
- **THEN** it SHALL describe the technology as documented by its upstream maintainers
- **AND** it SHALL NOT reference project-specific code paths, config files, or architectural choices

### Requirement: External debug source fetching
The project SHALL provide `scripts/fetch-debug-source.sh` for on-demand fetching of external dependency source code into a gitignored `vendor/debug/` directory.

#### Scenario: Fetch external source
- **WHEN** a developer runs `scripts/fetch-debug-source.sh crun v1.19`
- **THEN** the script SHALL clone or download the specified version to `vendor/debug/crun/`
- **AND** the directory SHALL be gitignored

#### Scenario: Clean clone
- **WHEN** a new developer clones the repository
- **THEN** `vendor/debug/` SHALL NOT exist
- **AND** no external source code SHALL be downloaded automatically

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:knowledge-source-of-truth" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
