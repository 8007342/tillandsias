<!-- @trace spec:spec-traceability -->
## Status

status: active

## ADDED Requirements

### Requirement: Code annotations link to specs and knowledge
Critical code blocks and module headers SHALL have `// @trace` comments referencing the specs and knowledge cheatsheets that justify the implementation decision.

#### Scenario: Module-level trace
- **WHEN** a Rust module implements one or more spec capabilities
- **THEN** the module doc comment SHALL include `//! @trace spec:<capability>` listing primary specs

#### Scenario: Block-level trace
- **WHEN** a code block enacts a non-obvious architectural decision from a spec
- **THEN** a `// @trace spec:<capability>/<requirement-slug>` comment SHALL precede the block
- **AND** relevant knowledge cheatsheets MAY be included as `knowledge:<domain>/<topic>`

#### Scenario: Bash script trace
- **WHEN** a bash script implements spec requirements
- **THEN** critical sections SHALL have `# @trace spec:<capability>` comments

#### Scenario: Annotation coverage
- **WHEN** annotations are added
- **THEN** only the ~20% of code where architectural decisions live SHALL be annotated
- **AND** data types, tests, utilities, and plumbing code SHALL NOT be annotated

### Requirement: Structured spec field in tracing logs
Log events for operations a troubleshooting agent would encounter SHALL include a `spec` field referencing the backing specification.

#### Scenario: Instrumented function span
- **WHEN** a function is annotated with `#[instrument]`
- **THEN** it SHALL include `fields(spec = "<capability>")` with comma-separated capabilities if multiple apply

#### Scenario: Standalone log event
- **WHEN** an `info!`, `warn!`, or `error!` log event represents a container lifecycle operation, security enforcement, or error condition
- **THEN** it SHALL include `spec = "<capability>/<requirement-slug>"` as a structured field

#### Scenario: Log parsability
- **WHEN** a troubleshooting agent reads a structured log event
- **THEN** the `spec` field SHALL be directly usable as a path to `openspec/specs/<capability>/spec.md`

### Requirement: CRDT-like reference semantics
Trace references SHALL be conflict-free, incremental, and advisory — never blocking.

#### Scenario: Stale reference
- **WHEN** a `@trace` comment references a spec that has been archived or renamed
- **THEN** the code SHALL still compile and run without error
- **AND** the stale reference SHALL serve as a drift signal for future investigation

#### Scenario: Missing reference
- **WHEN** new code is added without `@trace` annotations
- **THEN** the build SHALL succeed
- **AND** the gap MAY be filled when the code is next modified or troubleshot

#### Scenario: Concurrent additions
- **WHEN** multiple developers add different `@trace` references to the same module
- **THEN** git merge SHALL handle the additions without conflict (comments on separate lines)

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

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:spec-traceability" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
