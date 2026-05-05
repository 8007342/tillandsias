## ADDED Requirements

### Requirement: Cheatsheets directory structure

The repository SHALL contain a top-level `cheatsheets/` directory organized into seven subdirectories: `runtime/`, `languages/`, `utils/`, `build/`, `web/`, `test/`, and `agents/`. Each subdirectory contains one cheatsheet per topic, named `<topic>.md` (lowercase, hyphenated).

#### Scenario: Subdirectory layout
- **WHEN** a contributor adds a new cheatsheet
- **THEN** they place it in the subdirectory that matches its primary use (`languages/python.md`, NOT `python/syntax.md`)

#### Scenario: Naming convention
- **WHEN** a cheatsheet covers a tool with a hyphenated name (e.g., `cargo-test`)
- **THEN** the filename uses the same hyphenation: `test/cargo-test.md`

### Requirement: Cheatsheet template

Every cheatsheet SHALL follow a fixed template with these sections in this order: title heading, `@trace spec:agent-cheatsheets` annotation, `**Version baseline**:` line, `**Use when**:` line, `## Quick reference`, `## Common patterns`, `## Common pitfalls`, `## See also`. Sections may be empty but the headings SHALL be present.

#### Scenario: Template enforcement
- **WHEN** a contributor or sub-agent writes a new cheatsheet
- **THEN** all required sections are present in the file
- **AND** the `@trace spec:agent-cheatsheets` line appears within the first five lines

#### Scenario: Length budget
- **WHEN** a cheatsheet is committed
- **THEN** its line count is ≤ 200 lines (a soft cap; longer cheatsheets SHOULD be split into multiple topic-scoped files instead)

### Requirement: INDEX.md is grep-friendly

The cheatsheets directory SHALL contain `cheatsheets/INDEX.md` listing every cheatsheet, grouped by category (one `## <category>` heading per subdirectory). Each entry is a single line of the form `- <filename>.md  — <one-line description>` (≤ 100 characters per line).

#### Scenario: INDEX format invariant
- **WHEN** an agent runs `cat /opt/cheatsheets/INDEX.md | rg '<topic>'`
- **THEN** the result is one line per matching cheatsheet, suitable for direct piping to `cut -d' ' -f2` to extract the filename

#### Scenario: Every cheatsheet is indexed
- **WHEN** `cheatsheets/<category>/<filename>.md` exists in the repository
- **THEN** `cheatsheets/INDEX.md` contains a corresponding line under the matching `## <category>` heading

### Requirement: Forge image bakes cheatsheets

The forge image (`images/default/Containerfile`) SHALL `COPY cheatsheets/ /opt/cheatsheets/` at image-build time and SHALL export `TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets` as a container environment variable. The directory inside the container SHALL be world-readable and read-only (no agent writes to `/opt/cheatsheets/`).

#### Scenario: Cheatsheets are present in the running forge
- **WHEN** the forge container starts
- **THEN** `ls /opt/cheatsheets/INDEX.md` succeeds inside the container
- **AND** every subdirectory under `cheatsheets/` in the source tree is present under `/opt/cheatsheets/` inside the container

#### Scenario: Environment variable is set
- **WHEN** an agent runs `echo $TILLANDSIAS_CHEATSHEETS` inside the forge
- **THEN** the output is `/opt/cheatsheets`

#### Scenario: Cheatsheets are read-only
- **WHEN** the forge user runs `touch /opt/cheatsheets/test.md`
- **THEN** the operation fails with permission denied — `/opt/cheatsheets/` is image-state, not user-state

### Requirement: RUNTIME_LIMITATIONS feedback channel

When an agent inside the forge encounters a missing tool, capability, or runtime constraint that prevented its task, it SHALL write a report to `<project>/.tillandsias/runtime-limitations/RUNTIME_LIMITATIONS_<NNN>.md` where `<NNN>` is the next sequential 3-digit number (zero-padded). The report SHALL include YAML front-matter with `report_id`, `tool`, `attempted`, `suggested_install`, and `discovered_at` fields, followed by a free-form body describing the gap.

#### Scenario: Sequential numbering
- **WHEN** an agent writes a new RUNTIME_LIMITATIONS report and the directory already contains `RUNTIME_LIMITATIONS_001.md` and `RUNTIME_LIMITATIONS_002.md`
- **THEN** the new file SHALL be `RUNTIME_LIMITATIONS_003.md`

#### Scenario: Front-matter is parseable
- **WHEN** a host-side script reads `<project>/.tillandsias/runtime-limitations/*.md`
- **THEN** each file's YAML front-matter contains the five required fields and the body is non-empty

#### Scenario: Reports survive forge stop via mirror sync
- **WHEN** the forge container stops after writing a RUNTIME_LIMITATIONS report
- **THEN** the report appears at `<host_watch_path>/<project>/.tillandsias/runtime-limitations/RUNTIME_LIMITATIONS_<NNN>.md` after the mirror-sync pass completes
