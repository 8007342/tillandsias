<!-- @trace spec:observability-convergence -->

# observability-convergence Specification

## Status

status: active

## Purpose

Track alignment between OpenSpec specs and runtime implementation via instrumented metrics. Measure code coverage of spec requirements, spec→code→trace traceability, and convergence toward spec intent. Enable data-driven decisions about spec completeness and implementation gaps.

This spec ensures:
- Specs have measurable implementation coverage
- Traces create observable links from code to spec
- Metrics feed back into prioritization
- Convergence is visible (not invisible drift)

## Requirements

### Requirement: Spec coverage metrics

Each spec requirement SHALL have an associated implementation marker and coverage metric.

#### Scenario: Requirement implementation count
- **WHEN** a spec has 10 Requirements
- **THEN** the tray calculates how many are referenced by `@trace spec:<name>` in the codebase
- **AND** computes coverage = (traced_requirements / total_requirements) * 100
- **AND** logs `spec = "<name>", coverage_percent = 75, traced_requirements = 7, total_requirements = 10`

#### Scenario: Zero coverage spec
- **WHEN** a new spec is written but not yet implemented
- **THEN** coverage is 0%
- **AND** the spec is flagged as `status: draft` or `status: active` but not yet merged
- **AND** the tray does not measure coverage until first implementation lands

#### Scenario: 100% coverage achieved
- **WHEN** all requirements in a spec have `@trace` annotations in the codebase
- **THEN** coverage is 100%
- **AND** the tray emits an event `spec_converged = true, spec_name = "<name>"`
- **AND** the spec is considered "locked" (further changes unlikely)

### Requirement: Trace cardinality and completeness

Traces SHALL be counted and validated to ensure they cover the spec they reference.

#### Scenario: Trace count per spec
- **WHEN** counting all `@trace spec:<name>` annotations in the codebase
- **THEN** the tray logs `spec = "<name>", trace_count = 42, trace_locations = ["src-tauri/src/handlers.rs:123", ...]`
- **AND** traces are grouped by file and function

#### Scenario: Dead trace detection
- **WHEN** a trace references a spec that no longer exists
- **THEN** the tray logs `dead_trace = true, spec = "<name>"` with file/line
- **AND** emits a warning (non-blocking) during startup

#### Scenario: Untraced code in spec-implementing module
- **WHEN** a file is known to implement a spec but lacks `@trace` markers
- **THEN** the tray suggests adding traces via a lint-style message
- **AND** tracks `untraced_implementation_risk = true` for that spec

### Requirement: Requirement↔Litmus Test binding

Each spec's Litmus Test section SHALL reference Requirements by name, creating a bidirectional binding.

#### Scenario: Litmus test covers requirement
- **WHEN** a Litmus Test has a test function that validates Requirement X
- **THEN** the tray parses the binding (e.g., `Test: <name> → Requirement: <name>`)
- **AND** computes litmus_coverage = (tested_requirements / total_requirements) * 100
- **AND** logs `spec = "<name>", litmus_coverage_percent = 60, tested_requirements = 6`

#### Scenario: Requirement untested
- **WHEN** a Requirement exists but no Litmus Test validates it
- **THEN** the tray flags it with `requirement_coverage_gap = true, spec = "<name>", requirement = "<name>"`
- **AND** logs at INFO level (visible but not blocking)

#### Scenario: Test without requirement binding
- **WHEN** a Litmus Test is present but does not reference a specific Requirement
- **THEN** the tray logs `test_without_requirement_binding = true, spec = "<name>", test_name = "<name>"`
- **AND** suggests adding a binding in the test's comment

### Requirement: Implementation latency — time from spec to code

Track how long a spec takes to move from "written" to "implementation merged".

#### Scenario: Spec created
- **WHEN** a new spec file is committed under `openspec/specs/`
- **THEN** the tray records the commit date in spec metadata
- **AND** begins tracking time-to-implementation

#### Scenario: First implementation lands
- **WHEN** a trace with `spec = "<name>"` appears in a committed file
- **THEN** the tray records the commit date of the first implementation
- **AND** calculates latency = (first_impl_date - spec_date)
- **AND** logs `spec = "<name>", latency_days = 5, status = "implemented"`

#### Scenario: Latency metrics aggregation
- **WHEN** computing aggregate stats
- **THEN** the tray reports:
  - Mean spec→implementation latency
  - Median latency
  - Specs with latency > 30 days (backlog risk)
  - Specs with latency < 1 day (fast convergence)

### Requirement: Spec debt and staleness

Specs without recent implementation or test updates are flagged as stale or drifting.

#### Scenario: Spec with no recent traces
- **WHEN** a spec's most recent trace is > 30 days old
- **THEN** the tray logs `spec_staleness = true, spec = "<name>", last_trace_date = "2026-04-03"`
- **AND** suggests reviewing the spec to ensure code still matches intent

#### Scenario: Requirement added to completed spec
- **WHEN** a new Requirement is added to a spec marked `status: active` (not `status: draft`)
- **THEN** the tray flags `spec_debt_increase = true, spec = "<name>"` 
- **AND** logs the new requirement as untested/unimplemented
- **AND** resets coverage_percent if it was 100%

#### Scenario: Spec version tracking
- **WHEN** a spec is modified (new requirement, clarification)
- **THEN** a `spec_version = "v1.2"` field in the spec YAML/frontmatter is incremented
- **AND** the tray tracks which code versions reference which spec versions

### Requirement: Convergence scoring

Compute a convergence score reflecting how well the implementation aligns with spec intent.

#### Scenario: Perfect convergence
- **WHEN** a spec has:
  - 100% requirement implementation coverage
  - 100% litmus test coverage
  - All traces linked to Requirements
  - No dead traces
  - No stale requirements
- **THEN** convergence_score = 100
- **AND** the tray logs `spec = "<name>", convergence_score = 100, status = "locked"`

#### Scenario: Partial convergence
- **WHEN** a spec has:
  - 80% requirement coverage
  - 60% litmus test coverage
  - 5 untraced implementations
- **THEN** convergence_score = (0.8 * 0.4 + 0.95) / 2.5 ≈ 70 (weighted average)
- **AND** the tray logs `spec = "<name>", convergence_score = 70, status = "active"`

#### Scenario: Low convergence alert
- **WHEN** convergence_score < 50
- **THEN** the tray emits a warning at startup:
  ```
  Warning: spec:forge-launch has low convergence (35%). Review requirements and traces.
  ```

### Requirement: Litmus test — observability instrumentation

Critical verification paths:

#### Test: Spec coverage computation
```bash
# Count requirements in a spec
REQ_COUNT=$(grep -c "^### Requirement:" openspec/specs/app-lifecycle/spec.md)

# Count traces for that spec
TRACE_COUNT=$(grep -r "@trace spec:app-lifecycle" src-tauri/ --include="*.rs" | wc -l)

# Compute coverage
COVERAGE=$((TRACE_COUNT * 100 / REQ_COUNT))
echo "Coverage: $COVERAGE% ($TRACE_COUNT/$REQ_COUNT)"

# Verify tray reports same percentage
./tillandsias-tray --metrics 2>&1 | grep -i "app-lifecycle.*coverage"
# Expected: coverage_percent = $COVERAGE or similar
```

#### Test: Dead trace detection
```bash
# Create a trace to a spec that doesn't exist
sed -i 's/@trace spec:foo/@trace spec:nonexistent-spec/' src-tauri/src/main.rs

# Run coverage check
./tillandsias-tray --check-specs 2>&1
# Expected: "dead_trace = true, spec = nonexistent-spec, file = src-tauri/src/main.rs"

# Revert
git checkout src-tauri/src/main.rs
```

#### Test: Latency tracking
```bash
# Create new spec
cat > openspec/specs/test-latency/spec.md << 'EOF'
<!-- @trace spec:test-latency -->
# Test Latency Spec
## Requirements
### Requirement: Test requirement
## Sources of Truth
EOF
git add openspec/specs/test-latency/spec.md
git commit -m "test: create latency spec"

# Record spec creation time
SPEC_DATE=$(git log -1 --format=%aI openspec/specs/test-latency/spec.md)

# Add implementation trace
echo "// @trace spec:test-latency" >> src-tauri/src/test.rs
git add src-tauri/src/test.rs
git commit -m "test: implement latency spec"

# Record implementation time
IMPL_DATE=$(git log -1 --format=%aI src-tauri/src/test.rs)

# Run latency check
./tillandsias-tray --metrics 2>&1 | grep -i "test-latency.*latency"
# Expected: latency_days = 0 (same commit), or latency_days = N if separate
```

#### Test: Convergence score
```bash
# Query convergence for multiple specs
./tillandsias-tray --metrics --format=json 2>&1 | jq '.specs[] | {name, convergence_score}'
# Expected: JSON array with convergence_score for each spec

# Verify 100% coverage specs show convergence_score = 100
./tillandsias-tray --metrics 2>&1 | grep -B1 "convergence_score = 100"
# Expected: spec names with perfect convergence
```

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:observability-convergence" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```

Log events SHALL include:
- `spec = "observability-convergence"` on all convergence events
- `spec_name = "<name>"` identifying the spec being measured
- `coverage_percent = N` for requirement implementation coverage
- `litmus_coverage_percent = N` for test coverage
- `convergence_score = N` aggregate metric
- `latency_days = N` from spec creation to first implementation
- `spec_staleness = true` when last trace is > 30 days old
- `dead_trace = true` when trace references non-existent spec

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- pending — test binding required for S2→S3 progression

Gating points:
- Trace annotation points to valid spec in openspec/specs/ directory
- Log events include structured fields: spec, trace_timestamp, implementation_timestamp
- Convergence score computed as (implementation_traces / active_specs) * 100
- Spec staleness detected when last trace is > 30 days old
- Dead traces (referencing non-existent specs) flagged in validation and logged as `dead_trace=true`
- Latency from spec creation to first trace recorded and reported
- All accountability events include spec, timestamp, and source context

## Sources of Truth

- `cheatsheets/observability/cheatsheet-metrics.md` — metric definitions and aggregation patterns
- `cheatsheets/runtime/logging-levels.md` — structured logging for observability events
- `cheatsheets/runtime/cheatsheet-crdt-overrides.md` — CRDT and convergence patterns for spec↔code alignment
- `cheatsheets/runtime/cheatsheet-architecture-v2.md` — instrumentation hooks and telemetry architecture

