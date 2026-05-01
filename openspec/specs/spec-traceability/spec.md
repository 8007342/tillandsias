<!-- @trace spec:spec-traceability -->
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
