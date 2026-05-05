<!-- @trace spec:methodology-accountability -->

# Methodology Accountability Specification

## Status

active

## Purpose

Make the methodology itself auditable. The project already requires specs,
cheatsheets, traces, litmus tests, and evidence bundles for implementation work.
This spec extends the same discipline to methodology claims, unknown-event intake,
and correctness-proximity scoring.

## Requirements

### Requirement: Methodology claims cite provenance
- **ID**: methodology-accountability.claims.provenance@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [methodology-accountability.invariant.claims-have-provenance]

Normative methodology claims SHALL have stable claim IDs and cite either an
external source, an internal evidence bundle, or an explicit project-practice
record. External analogies SHALL name their limits.

#### Scenario: Claim with external standard
- **WHEN** a methodology rule derives from RFC 2119, W3C PROV, Lamport clocks,
  CRDT literature, OpenTelemetry semantic conventions, or a weighted scoring
  analogy
- **THEN** `methodology/provenance.yaml` SHALL list the source URL
- **AND** SHALL include claim strength, inference, limits, and a falsification
  signal

#### Scenario: Claim without provenance
- **WHEN** a methodology rule is normative but lacks a provenance claim
- **THEN** the methodology SHALL treat it as an assumption
- **AND** proximity scoring SHALL apply the `methodology_claim_without_provenance`
  penalty where that claim supports a correctness score

### Requirement: Unknown events are first-class artifacts
- **ID**: methodology-accountability.events.unknown-intake@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [methodology-accountability.invariant.unknowns-distill]

Unexpected observations SHALL be captured under `methodology/event/` before they
are normalized away as implementation drift, spec churn, or agent memory.

#### Scenario: Unpredicted observation
- **WHEN** an agent observes behavior that contradicts or is not predicted by a
  spec, litmus test, trace, cheatsheet, proximity score, or methodology claim
- **THEN** it SHALL create or update `methodology/event/NN-short-slug.yaml`
- **AND** SHALL record observed signal, expected model, affected artifacts,
  evidence references, uncertainty delta, next distillation step, and closure
  criteria

#### Scenario: High uncertainty event
- **WHEN** an unknown event has `uncertainty_delta: high`
- **THEN** closure SHALL require either a bounded uncertainty exception or an
  update to a spec, litmus test, cheatsheet, provenance claim, proximity rule, or
  runtime trace schema

### Requirement: Correctness proximity uses CentiColons
- **ID**: methodology-accountability.proximity.centicolons@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [methodology-accountability.invariant.centicolons-are-residual]

Correctness proximity SHALL be reported as CentiColons (`cc`), an auditable
obligation-closure unit. CentiColons SHALL measure named residual obligations,
not confidence, effort, proof, or lines of code.
The mathematical boundary for this claim SHALL be the finite obligation-state
model in `methodology/math-foundations.yaml`.

#### Scenario: Spec proximity report
- **WHEN** a dashboard or agent reports proximity for a spec
- **THEN** it SHALL include earned CentiColons, total CentiColon budget, residual
  CentiColons, top residual reasons, evidence bundle reference, and open unknown
  events

#### Scenario: Denominator changes
- **WHEN** spec requirements, invariants, litmus signals, or proximity weights
  change the total CentiColon budget
- **THEN** the report SHALL name the denominator change as a scope change
- **AND** SHALL NOT present the changed score as pure implementation progress

### Requirement: Existing convergence score remains coarse
- **ID**: methodology-accountability.proximity.convergence-score-boundary@v1
- **Modality**: SHOULD
- **Measurable**: true
- **Invariants**: [methodology-accountability.invariant.score-boundary-clear]

Existing `convergence_score` metrics SHOULD remain coarse coverage health
signals. They SHALL NOT replace CentiColon residuals when discussing proximity
to correctness.

### Requirement: Mathematical convergence claims are bounded
- **ID**: methodology-accountability.math.claim-boundary@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [methodology-accountability.invariant.math-nonclaims-explicit]

The methodology SHALL distinguish order-theoretic monotonicity, finite ranking
progress, metric contraction, and evidential confidence. It SHALL NOT claim
Banach-style contraction, probabilistic correctness, or complete semantic proof
unless the required mathematical objects and validation evidence are defined.

#### Scenario: Defensible monotonic convergence claim
- **WHEN** the methodology says convergence is monotonic
- **THEN** it SHALL define the ordered state space, allowed monotone transitions,
  fixed denominator conditions, and non-monotone exception paths
- **AND** SHALL cite `methodology/math-foundations.yaml`

#### Scenario: Stronger mathematical claim
- **WHEN** documentation claims contraction, probability, or proof
- **THEN** it SHALL define the needed metric/probability/proof objects
- **OR** SHALL downgrade the claim to evidence, ranking progress, or analogy

## Invariants

### Invariant: Claims have provenance
- **ID**: methodology-accountability.invariant.claims-have-provenance
- **Expression**: `normative_methodology_claims HAVE claim_id AND provenance_or_assumption_status`
- **Measurable**: true

### Invariant: Unknowns distill into durable artifacts
- **ID**: methodology-accountability.invariant.unknowns-distill
- **Expression**: `closed_unknown_event => learned_distinction_preserved_in_spec_or_litmus_or_methodology_or_cheatsheet_or_trace`
- **Measurable**: true

### Invariant: CentiColons are residual obligations
- **ID**: methodology-accountability.invariant.centicolons-are-residual
- **Expression**: `reported_cc_score INCLUDES earned_cc,total_cc,residual_cc,residual_reasons`
- **Measurable**: true

### Invariant: Score boundary is clear
- **ID**: methodology-accountability.invariant.score-boundary-clear
- **Expression**: `convergence_score != centicolon_residual_score`
- **Measurable**: true

### Invariant: Mathematical nonclaims are explicit
- **ID**: methodology-accountability.invariant.math-nonclaims-explicit
- **Expression**: `methodology_math_claims DISTINGUISH lattice_monotonicity,ranking_progress,metric_contraction,evidence_confidence`
- **Measurable**: true

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- pending - methodology accountability validator not implemented yet

Gating points:
- `methodology/provenance.yaml` contains claim IDs, source refs, limits, and
  falsification signals
- `methodology/event/index.yaml` defines required fields for unknown intake
- `methodology/event/000-template-unpredicted.yaml` contains all required fields
- `methodology/proximity.yaml` defines CentiColon unit, budget, earning rules,
  penalties, rollup, anti-gaming, and calibration rules
- `methodology/math-foundations.yaml` defines formal objects, convergence claims,
  validation program, and explicit non-claims
- `methodology.yaml` includes the new components in bootstrap and navigation

## Sources of Truth

- `methodology/provenance.yaml` - methodology claim provenance model
- `methodology/event/index.yaml` - unknown-event intake model
- `methodology/proximity.yaml` - CentiColon proximity model
- `methodology/math-foundations.yaml` - mathematical foundations and validation program
- `cheatsheets/observability/cheatsheet-metrics.md` - existing scoring and metrics patterns
- `docs/cheatsheets/openspec-methodology.md` - OpenSpec convergence workflow

External references:
- RFC 2119: <https://www.rfc-editor.org/rfc/rfc2119>
- W3C PROV-DM: <https://www.w3.org/TR/prov-dm/>
- W3C PROV Constraints: <https://www.w3.org/TR/prov-constraints/>
- Lamport clocks: <https://www.microsoft.com/en-us/research/publication/time-clocks-ordering-events-distributed-system/>
- CRDT study: <https://hal.inria.fr/inria-00555588>
- OpenTelemetry semantic conventions: <https://opentelemetry.io/docs/specs/semconv/>
- Tarski fixed-point theorem: <https://doi.org/10.2140/pjm.1955.5.285>
- Cousot and Cousot abstract interpretation: <https://doi.org/10.1145/512950.512973>
- Banach contraction principle: <https://doi.org/10.4064/fm-3-1-133-181>

## Observability

Annotations referencing this spec can be found by:

```bash
rg -n "@trace spec:methodology-accountability|spec:methodology-accountability" methodology openspec docs cheatsheets scripts src-tauri crates images
```
