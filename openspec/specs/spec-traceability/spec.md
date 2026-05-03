<!-- @trace spec:spec-traceability -->
## Status

status: active

## Requirements

### Requirement: Code annotations link to specs and knowledge
- **ID**: spec-traceability.annotation.trace-coverage@v1
- **Modality**: SHOULD
- **Measurable**: true
- **Invariants**: [spec-traceability.invariant.architectural-decisions-annotated, spec-traceability.invariant.annotation-coverage-20-percent]
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
- **ID**: spec-traceability.logging.spec-field-instrumentation@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [spec-traceability.invariant.spec-field-in-critical-logs, spec-traceability.invariant.spec-field-path-usable]
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
- **ID**: spec-traceability.annotation.crdt-references@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [spec-traceability.invariant.stale-reference-no-build-error, spec-traceability.invariant.missing-annotation-no-build-error, spec-traceability.invariant.merge-concurrent-annotations]
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
- **ID**: spec-traceability.cheatsheet.draft-warning@v1
- **Modality**: SHOULD
- **Measurable**: true
- **Invariants**: [spec-traceability.invariant.draft-cheatsheet-warning-emitted, spec-traceability.invariant.draft-exemption-during-retrofit]

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
- **ID**: spec-traceability.annotation.cheatsheet-code-citation@v1
- **Modality**: SHOULD
- **Measurable**: true
- **Invariants**: [spec-traceability.invariant.cheatsheet-annotation-coexists-with-trace, spec-traceability.invariant.cheatsheet-log-field-queryable]

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

## Invariants

### Invariant: Architectural decisions are annotated
- **ID**: spec-traceability.invariant.architectural-decisions-annotated
- **Expression**: `code_blocks_with_non_obvious_decisions HAVE @trace_or_@cheatsheet_comments`
- **Measurable**: true

### Invariant: Annotation coverage is 20%
- **ID**: spec-traceability.invariant.annotation-coverage-20-percent
- **Expression**: `annotated_lines / total_lines ≈ 0.20 && excludes(data_types, tests, utilities, plumbing)`
- **Measurable**: true

### Invariant: Spec field in critical logs
- **ID**: spec-traceability.invariant.spec-field-in-critical-logs
- **Expression**: `container_lifecycle_or_security_log_events INCLUDE spec="<capability>/<slug>" field`
- **Measurable**: true

### Invariant: Spec field path is usable
- **ID**: spec-traceability.invariant.spec-field-path-usable
- **Expression**: `spec_field_value MATCHES openspec/specs/<capability>/spec.md && file_exists`
- **Measurable**: true

### Invariant: Stale reference does not error
- **ID**: spec-traceability.invariant.stale-reference-no-build-error
- **Expression**: `@trace spec:archived_or_renamed => code_compiles && serves_as_drift_signal`
- **Measurable**: true

### Invariant: Missing annotation does not error
- **ID**: spec-traceability.invariant.missing-annotation-no-build-error
- **Expression**: `new_code_without_@trace => build_succeeds && gap_may_fill_later`
- **Measurable**: true

### Invariant: Concurrent annotations merge without conflict
- **ID**: spec-traceability.invariant.merge-concurrent-annotations
- **Expression**: `concurrent_@trace_additions_on_adjacent_lines => git_merge_succeeds`
- **Measurable**: true

### Invariant: DRAFT cheatsheet citation emits warning
- **ID**: spec-traceability.invariant.draft-cheatsheet-warning-emitted
- **Expression**: `spec.sources_of_truth CITES DRAFT_cheatsheet => openspec_validate_emits_warning`
- **Measurable**: true

### Invariant: DRAFT exemption during retrofit
- **ID**: spec-traceability.invariant.draft-exemption-during-retrofit
- **Expression**: `validation_passes_with_warning && existing_specs_exempt_until_retrofit`
- **Measurable**: true

### Invariant: Cheatsheet annotation coexists with trace
- **ID**: spec-traceability.invariant.cheatsheet-annotation-coexists-with-trace
- **Expression**: `code_site_using_both_spec_and_cheatsheet => BOTH_@trace_AND_@cheatsheet_present`
- **Measurable**: true

### Invariant: Cheatsheet log field is queryable
- **ID**: spec-traceability.invariant.cheatsheet-log-field-queryable
- **Expression**: `log_event.cheatsheet_field => rg 'cheatsheet = "..."' finds_all_events`
- **Measurable**: true

## Litmus Tests

The following litmus tests validate spec-traceability requirements:

- `litmus-annotation-coverage.yaml` — Validates trace annotation coverage (~20% of code) (Req: spec-traceability.annotation.trace-coverage@v1)
- `litmus-spec-field-instrumentation.yaml` — Validates structured spec field in critical logs (Req: spec-traceability.logging.spec-field-instrumentation@v1)
- `litmus-crdt-annotation-semantics.yaml` — Validates CRDT-like reference non-blocking properties (Req: spec-traceability.annotation.crdt-references@v1)
- `litmus-cheatsheet-citation-graph.yaml` — Validates cheatsheet→code→spec queryable graph (Req: spec-traceability.annotation.cheatsheet-code-citation@v1)

See `openspec/litmus-bindings.yaml` for full binding definitions.

## Sources of Truth

- `cheatsheets/observability/cheatsheet-metrics.md` — Metrics and traceability patterns
- `cheatsheets/agents/openspec.md` — OpenSpec methodology and spec-driven development

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:spec-traceability" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
