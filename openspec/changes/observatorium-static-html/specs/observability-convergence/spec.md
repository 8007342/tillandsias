## MODIFIED Requirements

### Requirement: Dashboard is a read-only projection

The CentiColon dashboard SHALL be a read-only projection of the signature log, rendered to `target/convergence/centicolon-dashboard.md` and `target/convergence/centicolon-dashboard.json` by default. It SHALL NOT be committed: `docs/convergence/centicolon-dashboard.*` is retired (operator ruling 2026-11-09, order 2066-obsv), and published release evidence is the observatorium site. Hand-edits SHALL be considered drift and SHALL be reverted on the next regeneration.

#### Scenario: Dashboard regenerated from signature log
- **WHEN** `scripts/update-convergence-dashboard.sh` runs
- **THEN** both `.md` and `.json` artefacts SHALL be overwritten from `target/convergence/centicolon-signature.jsonl`
- **AND** the `.md` SHALL include the auto-generation header `<!-- THIS FILE IS AUTO-GENERATED ... DO NOT EDIT. -->`
- **AND** the `.json` SHALL include a `dashboard_contract` object describing signature format, refresh policy, alert thresholds, and the source-of-truth integration

#### Scenario: Dashboard is never committed
- **WHEN** `scripts/update-convergence-dashboard.sh` runs with no `MD_OUT` or `JSON_OUT` set, from release preflight, local CI, or the post-commit refresh hook
- **THEN** it SHALL write only under `target/convergence/`
- **AND** no `docs/convergence/centicolon-dashboard.md` or `.json` SHALL exist in the repository

#### Scenario: Dashboard cites the source-of-truth spec
- **WHEN** the dashboard is rendered
- **THEN** the `.md` SHALL include a section pointing to `openspec/specs/knowledge-source-of-truth/spec.md`
- **AND** the `.json` SHALL include `dashboard_contract.integration.source_of_truth = "openspec/specs/knowledge-source-of-truth/spec.md"`

#### Scenario: Dashboard staleness
- **WHEN** a downstream consumer reads the dashboard
- **THEN** it MAY treat the snapshot as stale if `generated_at` is more than `dashboard_contract.refresh_policy.staleness_threshold_hours` (default 24h) older than the consumer's current time
- **AND** stale snapshots SHALL NOT be cited as authoritative evidence for spec convergence
