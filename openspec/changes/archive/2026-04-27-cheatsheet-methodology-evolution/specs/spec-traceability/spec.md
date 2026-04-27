## ADDED Requirements

### Requirement: Specs SHOULD prefer non-DRAFT cheatsheets in Sources of Truth

When a spec lists cheatsheets under its `## Sources of Truth` section, it SHOULD prefer cheatsheets without the DRAFT banner. Citing a DRAFT cheatsheet is permitted (because the alternative — leaving Sources of Truth empty — is worse for traceability), but `openspec validate` SHALL emit a warning so the citation is flagged for resolution when the cheatsheet is retrofitted.

#### Scenario: Spec citing a DRAFT cheatsheet emits a warning
- **WHEN** a spec's `## Sources of Truth` section cites `cheatsheets/languages/python.md`
- **AND** that cheatsheet currently carries the DRAFT banner
- **THEN** `openspec validate` SHALL emit a warning naming the spec and the DRAFT cheatsheet
- **AND** validation SHALL still pass (warning is non-blocking — the DRAFT exemption is intentional during the retrofit window)

#### Scenario: Spec citing a non-DRAFT cheatsheet passes cleanly
- **WHEN** a spec cites a cheatsheet whose `## Provenance` section is populated AND no DRAFT banner is present
- **THEN** `openspec validate` SHALL emit no warning for that citation

### Requirement: @cheatsheet path annotation in code is a peer of @trace spec:

Code, configuration, and log events SHALL cite cheatsheets they relied on using `@cheatsheet <category>/<filename>.md` annotations, structurally analogous to `@trace spec:<name>`. Both annotations SHALL coexist on the same code site when both apply.

The `@cheatsheet` annotation enables a queryable graph:
- `git grep '@cheatsheet'` finds every code citation
- `rg 'cheatsheet = "'` against logs finds every runtime citation
- OpenSpec's existing `## Sources of Truth` lists per-spec citations

Together these form a navigable cheatsheet→code→spec→log graph that lets reviewers trace any single behaviour back to the authoritative source it derived from.

#### Scenario: Function with both @trace and @cheatsheet annotations
- **WHEN** a Rust function implements behaviour governed by both a spec and a cheatsheet
- **THEN** the function comment SHALL contain BOTH `// @trace spec:<name>` AND `// @cheatsheet <category>/<filename>.md` on adjacent lines
- **AND** both annotations SHALL be picked up by `git grep`

#### Scenario: Log event with both spec and cheatsheet fields
- **WHEN** an `info!` / `warn!` / `error!` event emits with `accountability = true` because of cheatsheet-derived behaviour
- **THEN** the event SHALL include both `spec = "<name>"` and `cheatsheet = "<category>/<filename>.md"` as structured fields

## Sources of Truth

- `cheatsheets/agents/openspec.md` (DRAFT) — the workflow this change is part of.
