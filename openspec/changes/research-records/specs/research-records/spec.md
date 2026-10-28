## ADDED Requirements

### Requirement: A research record is a claim with a complete provenance chain

A research record SHALL be a Markdown file at `research/<domain>/<slug>.md`
with YAML frontmatter carrying `id` (= `<domain>/<slug>`), a one-sentence
`claim`, a non-empty `applies_to`, a non-empty `sources` list whose entries
each carry `url`, `kind`, `retrieved` and `archived` (archive URL or
`pending: <reason>`), `authority`, `strength`, `since`, `last_verified`,
`status` and `origin`, and a body with a `## Provenance` section.

@trace spec:research-records

#### Scenario: A record without sources is refused
- **WHEN** the validator reads a record with no `sources`
- **THEN** it exits 1 naming the path and `sources:missing-provenance`

### Requirement: The shared library ships in the forge image beside the cheatsheets

`research/` SHALL be copied to `/opt/research` with
`TILLANDSIAS_RESEARCH=/opt/research`; `research/INDEX.md` SHALL be generated.

@trace spec:research-records

#### Scenario: The library validates in the pre-build suite
- **WHEN** `litmus:research-records-shape` runs
- **THEN** every shipped record passes and the Containerfile carries the copy

### Requirement: Research is cited the way cheatsheets are cited

Agents SHALL cite `research:<id>` (`@research <id>` in code, "as per
research:<id>, ..." in prose, `Research: <id>` trailer).

@trace spec:research-records

#### Scenario: A design decision carries its research
- **WHEN** an agent decides how two parts relate
- **THEN** the design says which record supports the decision and why

### Requirement: Caches follow the storage direction

Fetched sources SHALL go to `${XDG_CACHE_HOME:-~/.cache}/tillandsias/research/`.

@trace spec:research-records

#### Scenario: A pulled-in PDF is not committed
- **WHEN** a source is downloaded to read
- **THEN** only the record appears in `git status`
