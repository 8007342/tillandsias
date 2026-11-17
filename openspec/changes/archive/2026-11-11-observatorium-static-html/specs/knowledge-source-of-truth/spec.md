## MODIFIED Requirements

### Requirement: Integration with downstream observability surfaces

This spec SHALL be the upstream input for every observability surface that reports on convergence. Downstream surfaces (dashboards, litmus reports, evidence bundles, trace indexes) SHALL cite this spec by name and SHALL respect the authority hierarchy, CRDT semantics, and divergence-resolution rules defined here.

#### Scenario: Dashboard cites this spec
- **WHEN** the CentiColon dashboard (`target/convergence/centicolon-dashboard.md`, rendered locally and not committed since order 2066-obsv) is regenerated
- **THEN** it SHALL include a pointer back to `openspec/specs/knowledge-source-of-truth/spec.md`
- **AND** the dashboard SHALL describe itself as a read-only projection of this spec's evidence semantics

#### Scenario: Observability event includes source-of-truth field
- **WHEN** a log event reports a convergence measurement (coverage, staleness, drift)
- **THEN** the event MAY include `source_of_truth = "knowledge-source-of-truth"` to signal which epistemology the measurement applies to
- **AND** future surfaces interpreting the event SHALL fall back to that spec for interpretation rules
