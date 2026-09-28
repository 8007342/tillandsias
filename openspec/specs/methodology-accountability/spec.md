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
<!-- req-id: 348030a1 -->
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
<!-- req-id: 1440983f -->
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
<!-- req-id: 9e6b3ea2 -->
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
<!-- req-id: c39441c8 -->
- **ID**: methodology-accountability.proximity.convergence-score-boundary@v1
- **Modality**: SHOULD
- **Measurable**: true
- **Invariants**: [methodology-accountability.invariant.score-boundary-clear]

Existing `convergence_score` metrics SHOULD remain coarse coverage health
signals. They SHALL NOT replace CentiColon residuals when discussing proximity
to correctness.

### Requirement: Mathematical convergence claims are bounded
<!-- req-id: f22c47b3 -->
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

### Requirement: Plan ledger models the distillation layer
<!-- req-id: e45b37c5 -->
- **ID**: methodology-accountability.distillation.plan-ledger@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [methodology-accountability.invariant.distillation-layer-explicit]

The `./plan` ledger SHALL model the epistemic distillation layer between formal
specifications (`openspec/`), systemic invariants, platform reality, and concrete code
implementations. Packets SHALL represent discrete state transitions ($\Delta$), not
static correctness debt coordinates.

#### Scenario: Spec feature distillation
- **WHEN** a plan packet implements or refines a user-visible functional contract
- **THEN** its `verifiable_closure` SHALL cite `centicolon: <req-id>[, ...]`
- **AND** the obligation grader SHALL verify the named scenarios achieve $\ge$ `positively_tested`

#### Scenario: Invariant and platform defect distillation
- **WHEN** a plan packet resolves a systemic invariant violation (toolchain, pipe elimination,
  determinism) or a platform/dev-box quirk (macOS Darwin, Windows WSL, Forge tmpfs)
- **THEN** it SHALL NOT pollute product specifications
- **AND** its `verifiable_closure` SHALL cite `centicolon: inv:<id>` or `centicolon: env:<id>`
- **AND** it SHALL be verified by an executable, deterministic Lua Litmus test

#### Scenario: Operational maintenance transition
- **WHEN** a plan packet executes non-functional repository maintenance (salvage sweeps,
  lease handoffs, fragment relays)
- **THEN** it SHALL declare `maintenance: <verifiable-command>`
- **AND** SHALL NOT modify the stationary obligation denominator ($\Delta \mathcal{R} = 0$)

### Requirement: Dual-domain obligation extraction via Lua substrate
<!-- req-id: a1b71f16 -->
- **ID**: methodology-accountability.extraction.lua-substrate@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [methodology-accountability.invariant.pure-obligation-extraction]

Obligation extraction and static grading SHALL be implemented as deterministic,
content-addressed `Cacheable` Lua predicates running within the hermetic runtime
without host dependencies, external shell pipes, or subshells. The obligation universe
SHALL explicitly decompose into spec contracts ($S_{\text{spec}}$), systemic invariants
($S_{\text{inv}}$), and platform preconditions ($S_{\text{env}}$).

#### Scenario: Deterministic obligation list
- **WHEN** the Lua extractor executes over repository bytes
- **THEN** it SHALL emit sorted canonical JSON whose SHA-256 digest is byte-identical
  across Linux, macOS, Windows, and Forge hosts
- **AND** it SHALL report unregistered or unkeyed artifacts explicitly

#### Scenario: Invariant execution inside the pre-push gate
- **WHEN** `./build.sh --check` executes
- **THEN** pure `Cacheable` Lua Litmus tests asserting systemic invariants SHALL run
- **AND** their pass/fail results SHALL witness active invariant verification before push

### Requirement: Invariant yield and verifiable closure for transient packets
<!-- req-id: 5ee5d6af -->
- **ID**: methodology-accountability.transient.invariant-yield@v1
- **Modality**: SHOULD
- **Measurable**: true
- **Invariants**: [methodology-accountability.invariant.transient-yields-invariants]

Transient work (bug fixes, flake defusals, harness repairs) SHOULD yield durable
machine-checkable invariants rather than prose assurances. The convergence engine
SHALL track the invariant-yield ratio across closed bug-class packets.

#### Scenario: Bug closure produces durable invariant
- **WHEN** a bug-class packet closes
- **THEN** it SHOULD produce a new or updated invariant litmus test or gate decider
  with pre-fix failure evidence
- **OR** SHALL explicitly declare `unscoreable: <why-no-invariant-produced>`

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

### Invariant: Distillation layer is explicit
- **ID**: methodology-accountability.invariant.distillation-layer-explicit
- **Expression**: `plan_packets ACT_AS state_transitions_delta AND DO_NOT_MIX queue_length_into_ranking_denominator`
- **Measurable**: true

### Invariant: Pure obligation extraction
- **ID**: methodology-accountability.invariant.pure-obligation-extraction
- **Expression**: `sha256(lua_extractor_output) IDENTICAL_ACROSS_PLATFORMS`
- **Measurable**: true

### Invariant: Transient work yields invariants
- **ID**: methodology-accountability.invariant.transient-yields-invariants
- **Expression**: `closed_bug_packets YIELD durable_litmus_or_decider_invariant`
- **Measurable**: true

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:methodology-accountability-shape` - Verify the methodology authority surface stays anchored to its trace, provenance, and support files

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
