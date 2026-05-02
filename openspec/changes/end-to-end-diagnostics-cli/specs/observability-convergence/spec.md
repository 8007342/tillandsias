<!-- @trace spec:observability-convergence -->

# observability-convergence Specification

## Purpose

Define structured observability patterns that enable bidirectional traceability between runtime behavior and system design. Every code path implementing a spec requirement SHALL emit observable signals (log events with `spec=` and `cheatsheet=` attributes) linked back to the spec via `@trace` annotations. This creates "observable convergence": code and specs move toward each other monotonically, validated by runtime logs.

## ADDED Requirements

### Requirement: Code annotations link implementation to specs

Every code block implementing a spec requirement SHALL include a `@trace spec:<name>` annotation identifying the spec it satisfies. Annotations appear as comments near the function, handler, or branch that implements the behavior.

#### Scenario: Handler function annotated
- **WHEN** the `handle_diagnostics()` function in `handlers.rs` is called to stream logs
- **THEN** the function begins with `// @trace spec:cli-diagnostics` comment
- **AND** grep search `@trace spec:cli-diagnostics` returns all code implementing that spec

#### Scenario: Multi-spec annotation for shared code
- **WHEN** a single code block serves two specs (e.g., init + observability)
- **THEN** it includes `// @trace spec:init-command, spec:observability-convergence` annotations

#### Scenario: Trace annotations are searchable
- **WHEN** developer searches GitHub: `@trace spec:cli-diagnostics site:github.com/user/tillandsias`
- **THEN** all implementation files for that spec appear in results
- **AND** a clickable GitHub link in commit messages makes this automatic

### Requirement: Log events emit spec and cheatsheet attributes

Every observable event (log entry, telemetry, error) from code implementing this change SHALL include `spec=` and `cheatsheet=` attributes identifying the relevant spec and cheatsheet resource.

#### Scenario: Diagnostics handler logs with spec attribute
- **WHEN** `handle_diagnostics()` begins tailing logs
- **THEN** it emits: `event="diagnostics_start" spec="cli-diagnostics" project="/path/to/project" containers=6`
- **AND** the `spec=` attribute is queryable via structured log search (grep, journalctl, etc.)

#### Scenario: Cheatsheet reference in event
- **WHEN** diagnostics encounters a container log format requiring interpretation
- **THEN** event includes: `cheatsheet="docs/cheatsheets/podman-logging.md"`
- **AND** operator can quickly reference the cheatsheet for format details

#### Scenario: Error events include spec context
- **WHEN** diagnostics fails to find running containers
- **THEN** it logs: `level=warn event="no_containers" spec="cli-diagnostics" message="No running Tillandsias containers found"`

### Requirement: Cheatsheets provide provenance and version anchors

Every cheatsheet informing this change's implementation SHALL include a `## Provenance` section citing source URLs and a `Last updated:` date. This pins tool versions and makes staleness visible.

#### Scenario: Cheatsheet provenance section
- **WHEN** reviewing `docs/cheatsheets/podman-logging.md`
- **THEN** it includes:
  ```
  ## Provenance
  - https://docs.podman.io/en/latest/markdown/podman-logs.1.html — official podman-logs command reference
  - Last updated: 2026-05-01
  ```

#### Scenario: Spec references cheatsheets in Sources of Truth
- **WHEN** viewing `specs/cli-diagnostics/spec.md`
- **THEN** bottom section lists:
  ```
  ## Sources of Truth
  - `docs/cheatsheets/podman-logging.md` — `podman logs` options and filtering patterns
  ```

#### Scenario: Tool version change invalidates cheatsheet
- **WHEN** podman ships a breaking change (new log format, removed option)
- **THEN** the `Last updated` date is stale, visible in cheatsheet age
- **AND** this becomes a signal to update the cheatsheet (separate task)

### Requirement: Implementation converges toward spec via trace links

Every spec requirement SHALL be linked bidirectionally to implementation: code emits `@trace spec:` annotations and logs emit `spec=` attributes, enabling grep/search to show the entire dependency graph (spec ← requirement statement ← code ← logs).

#### Scenario: Trace links are bidirectional
- **WHEN** developer reads spec: "Diagnostics SHALL stream logs with source labels"
- **AND** searches GitHub for `@trace spec:cli-diagnostics`
- **AND** finds the handler implementation
- **AND** searches logs for `spec="cli-diagnostics"`
- **THEN** they can trace the full path: spec → code → runtime behavior

#### Scenario: Convergence is observable in commits
- **WHEN** viewing a commit implementing spec changes
- **THEN** the commit message includes: 
  ```
  feat: add --diagnostics flag for container log streaming
  @trace spec:cli-diagnostics
  https://github.com/user/tillandsias/search?q=%40trace+spec%3Acli-diagnostics&type=code
  ```
- **AND** clicking the search link shows all spec-related code

#### Scenario: Specs and implementation are monotonically converging
- **WHEN** examining git history for a spec
- **THEN** every implementation commit references the spec via `@trace`
- **AND** every modification updates the spec via delta spec (never silent code drift)
- **AND** no implementation exists without a spec (or spec without implementation)

## Sources of Truth

- `docs/cheatsheets/podman-logging.md` — `podman logs` options, filtering patterns, log format interpretation
- `docs/cheatsheets/container-lifecycle.md` — container state machine and status checks
