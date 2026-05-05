<!-- @trace spec:knowledge-source-of-truth -->
## Status

status: active

## Requirements

### Requirement: Knowledge directory structure
The project MUST maintain a `knowledge/` directory at the repository root containing project-agnostic technology cheatsheets organized by domain.

#### Scenario: Directory layout
- **WHEN** a developer or agent inspects the `knowledge/` directory
- **THEN** it MUST contain: `index.xml`, `manifest.toml`, `README.md`, and a `cheatsheets/` subdirectory
- **AND** `cheatsheets/` MUST contain domain subdirectories: `infra/`, `lang/`, `frameworks/`, `packaging/`, `formats/`, `ci/`

### Requirement: Cheatsheet format
Each cheatsheet MUST be a Markdown file with YAML frontmatter containing: `id`, `title`, `category`, `tags`, `upstream`, `version_pinned`, `last_verified`, and `authority`.

#### Scenario: Cheatsheet structure
- **WHEN** an agent reads a cheatsheet file
- **THEN** the file MUST have YAML frontmatter with all required fields
- **AND** the Markdown body MUST contain focused, actionable reference content under 4K tokens
- **AND** the `authority` field MUST be one of: `official`, `community`, `derived`

#### Scenario: One topic per file
- **WHEN** a new cheatsheet is created
- **THEN** it MUST cover exactly one focused topic (e.g., `podman-rootless.md` not `podman.md`)
- **AND** an agent MUST be able to load the entire file in a single context read

### Requirement: XML collection index
The `knowledge/index.xml` file MUST provide a structured index of all cheatsheets organized by category and cross-referenced by tags.

#### Scenario: Category querying
- **WHEN** an agent needs all cheatsheets in a domain (e.g., `infra/containers`)
- **THEN** the index.xml MUST list all cheatsheets under that category with file path references

#### Scenario: Tag querying
- **WHEN** an agent needs cheatsheets related to a concept (e.g., `security`)
- **THEN** the index.xml MUST list all cheatsheet IDs tagged with that concept

### Requirement: Version tracking and freshness
The `knowledge/manifest.toml` file MUST track the upstream source, pinned version, and last verification date for each cheatsheet.

#### Scenario: Staleness detection
- **WHEN** a cheatsheet's `last_verified` date is older than 6 months
- **THEN** `scripts/verify-freshness.sh` MUST flag it as potentially stale

### Requirement: Project agnosticism
Knowledge cheatsheets MUST NOT contain references to Tillandsias, its codebase, its architecture, or any project-specific decisions.

#### Scenario: Content independence
- **WHEN** a cheatsheet is written or updated
- **THEN** it MUST describe the technology as documented by its upstream maintainers
- **AND** it MUST NOT reference project-specific code paths, config files, or architectural choices

### Requirement: External debug source fetching
The project MUST provide `scripts/fetch-debug-source.sh` for on-demand fetching of external dependency source code into a gitignored `vendor/debug/` directory.

#### Scenario: Fetch external source
- **WHEN** a developer runs `scripts/fetch-debug-source.sh crun v1.19`
- **THEN** the script MUST clone or download the specified version to `vendor/debug/crun/`
- **AND** the directory MUST be gitignored

#### Scenario: Clean clone
- **WHEN** a new developer clones the repository
- **THEN** `vendor/debug/` MUST NOT exist
- **AND** no external source code MUST be downloaded automatically

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- pending — test binding required for S2→S3 progression

Gating points:
- Cloned repository contains ONLY `openspec/vendor/` (no `vendor/debug/`)
- Developers run `/startup` or `/bootstrap-readme` to populate vendored knowledge
- All tools and agents are available after bootstrap; no runtime downloads needed
- Clean clone works offline (no network calls before bootstrap)
- Bootstrap completes within X seconds on typical hardware
- Vendored knowledge is read-only from developer perspective; updates come from CI/CD

## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:knowledge-source-of-truth" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
