<!-- @trace spec:knowledge-source-of-truth -->
# knowledge-source-of-truth Specification

## Status

status: active

## Purpose

This spec is the **epistemology** of Tillandsias: it defines what counts as authoritative knowledge, how artefacts converge over time, and how spec-vs-code divergence is resolved. Every other spec is interpreted *through* this spec. Observability surfaces (dashboards, signatures, evidence bundles) are downstream projections of the truth contract defined here.

The spec serves two intertwined concerns:

1. **Knowledge surface** — the `knowledge/` directory of vendored, project-agnostic cheatsheets and the `vendor/debug/` external-source escape hatch.
2. **Source-of-truth epistemology** — the authority hierarchy across code, specs, cheatsheets, and docs; CRDT-inspired monotonic convergence semantics; conflict resolution rules; staleness detection; and convergence evidence bundles.

Integration note: this spec governs how all other specs are *interpreted*. When another spec describes runtime behaviour, this spec defines what counts as evidence that the behaviour is correct and how to resolve divergence between spec text and code.

## Requirements

### Requirement: Knowledge directory structure
The project MUST maintain a `knowledge/` directory at the repository root containing project-agnostic technology cheatsheets organized by domain.

#### Scenario: Directory layout
- **WHEN** a developer or agent inspects the `knowledge/` directory
- **THEN** it MUST contain: `index.xml`, `manifest.toml`, `README.md`, and a `cheatsheets/` subdirectory
- **AND** `cheatsheets/` MUST contain domain subdirectories: `infra/`, `lang/`, `frameworks/`, `packaging/`, `formats/`, `ci/`

### Requirement: Cheatsheet format
Each cheatsheet MUST be a Markdown file with YAML frontmatter containing: `id`, `title`, `category`, `tags`, `upstream`, `version_pinned`, `last_verified`, and `authority`.

#### Scenario: Cheatsheet structure
- **WHEN** an agent reads a cheatsheet file
- **THEN** the file MUST have YAML frontmatter with all required fields
- **AND** the Markdown body MUST contain focused, actionable reference content under 4K tokens
- **AND** the `authority` field MUST be one of: `official`, `community`, `derived`

#### Scenario: One topic per file
- **WHEN** a new cheatsheet is created
- **THEN** it MUST cover exactly one focused topic (e.g., `podman-rootless.md` not `podman.md`)
- **AND** an agent MUST be able to load the entire file in a single context read

### Requirement: XML collection index
The `knowledge/index.xml` file MUST provide a structured index of all cheatsheets organized by category and cross-referenced by tags.

#### Scenario: Category querying
- **WHEN** an agent needs all cheatsheets in a domain (e.g., `infra/containers`)
- **THEN** the index.xml MUST list all cheatsheets under that category with file path references

#### Scenario: Tag querying
- **WHEN** an agent needs cheatsheets related to a concept (e.g., `security`)
- **THEN** the index.xml MUST list all cheatsheet IDs tagged with that concept

### Requirement: Version tracking and freshness
The `knowledge/manifest.toml` file MUST track the upstream source, pinned version, and last verification date for each cheatsheet.

#### Scenario: Staleness detection
- **WHEN** a cheatsheet's `last_verified` date is older than 6 months
- **THEN** `scripts/verify-freshness.sh` MUST flag it as potentially stale

### Requirement: Project agnosticism
Knowledge cheatsheets MUST NOT contain references to Tillandsias, its codebase, its architecture, or any project-specific decisions.

#### Scenario: Content independence
- **WHEN** a cheatsheet is written or updated
- **THEN** it MUST describe the technology as documented by its upstream maintainers
- **AND** it MUST NOT reference project-specific code paths, config files, or architectural choices

### Requirement: External debug source fetching
The project MUST provide `scripts/fetch-debug-source.sh` for on-demand fetching of external dependency source code into a gitignored `vendor/debug/` directory.

#### Scenario: Fetch external source
- **WHEN** a developer runs `scripts/fetch-debug-source.sh crun v1.19`
- **THEN** the script MUST clone or download the specified version to `vendor/debug/crun/`
- **AND** the directory MUST be gitignored

#### Scenario: Clean clone
- **WHEN** a new developer clones the repository
- **THEN** `vendor/debug/` MUST NOT exist
- **AND** no external source code MUST be downloaded automatically

### Requirement: Authority hierarchy across artefact classes

When the same fact is recorded in multiple artefact classes, agents and humans MUST resolve apparent conflicts by descending the authority hierarchy from highest to lowest. The hierarchy is **code > specs > cheatsheets > docs**.

- **Code** is the operational source of truth for *what the system actually does*. If a behaviour ships to users, that behaviour is normative until the spec or a litmus test rejects it.
- **Specs** are the normative source of truth for *what the system should do*. When code disagrees with a spec, the code is wrong and SHALL be corrected — never the other way around (see "Spec-vs-code divergence resolution" below).
- **Cheatsheets** are the source of truth for *how an upstream tool or technology behaves*. Specs cite cheatsheets in `## Sources of Truth`; cheatsheets in turn cite vendor or standards-body URLs.
- **Docs** (everything in `docs/`, `README.md`, plan files, in-line markdown) are derived, narrative surfaces. They MAY summarise or rephrase higher-authority artefacts but MUST NOT introduce normative claims that contradict them.

#### Scenario: Conflict between spec and doc
- **WHEN** a doc page asserts a behaviour that contradicts an active spec
- **THEN** the spec is authoritative
- **AND** the doc MUST be updated in a separate commit that cites the spec as the source

#### Scenario: Conflict between cheatsheet and vendor source
- **WHEN** a cheatsheet's pinned version disagrees with the vendor URL cited in its `## Provenance` section
- **THEN** the vendor URL is authoritative
- **AND** the cheatsheet MUST be refreshed (re-verified) and its `Last updated:` date bumped

#### Scenario: Code that has no spec
- **WHEN** code implements behaviour for which no spec exists
- **THEN** the behaviour is provisional and MUST NOT be cited as a source of truth
- **AND** a spec proposal SHOULD be filed before any other artefact references the behaviour

### Requirement: CRDT-inspired monotonic convergence

Knowledge artefacts SHALL behave as conflict-free replicated data types (CRDTs): updates SHALL be monotonic (additive), commutative when independent, and idempotent under replay. Two agents working on disjoint slices of the same artefact SHALL be able to merge their work without manual conflict resolution.

#### Scenario: Concurrent additions to a spec
- **WHEN** two agents each add a new Requirement to the same spec on separate branches
- **AND** the additions touch different `### Requirement:` headings
- **THEN** the merge SHALL succeed without intervention
- **AND** both Requirements SHALL appear in the merged spec

#### Scenario: Idempotent re-application of a checkpoint
- **WHEN** an agent re-runs a checkpoint with the same graph node id and lease id
- **THEN** the second application SHALL be a no-op
- **AND** repeated invocations SHALL converge to the same final state

#### Scenario: No hard conflicts on independent slices
- **WHEN** two changes modify disjoint sections of a markdown spec, JSON dashboard, or YAML binding file
- **THEN** the merge SHALL succeed automatically (line-oriented merge for markdown, structural merge for JSON/YAML)
- **AND** any genuine conflict SHALL signal that the slices were not truly disjoint and SHALL trigger an explicit resolution rather than a silent overwrite

#### Scenario: Removal requires a tombstone, not a silent delete
- **WHEN** a Requirement, code path, or cheatsheet is being removed
- **THEN** the removal SHALL leave a tombstone (`@tombstone superseded:<name>` or `@tombstone obsolete:<name>`) in the same artefact class as the original
- **AND** the tombstone SHALL satisfy the retention window defined in the project methodology
- **AND** the final deletion SHALL be a separate commit at the end of the retention window

### Requirement: Spec-vs-code divergence resolution

When code disagrees with the spec that governs it, the divergence SHALL be resolved by changing the code — not the spec. Specs converge toward *intent*, code converges toward *spec*. The only legitimate reason to change a spec in response to divergence is when the underlying intent itself changed; in that case the spec amendment SHALL precede the code change in the commit graph.

#### Scenario: Code ships behaviour the spec did not authorise
- **WHEN** a runtime trace, log event, or test reveals code behaviour that contradicts an active spec
- **THEN** the divergence SHALL be filed as a bug
- **AND** the code SHALL be corrected to match the spec in a follow-up commit
- **AND** the spec MUST NOT be retro-fitted to legitimise the rogue behaviour

#### Scenario: Intent itself changes
- **WHEN** product intent legitimately evolves and the existing spec no longer captures it
- **THEN** an OpenSpec change proposal SHALL be filed first
- **AND** the spec amendment SHALL land in `openspec/changes/<change>/specs/<capability>/spec.md` before any code change that depends on the new behaviour

#### Scenario: Drift signal in observability
- **WHEN** a litmus test fails because code drifted from spec
- **THEN** the failure SHALL surface in the CentiColon dashboard as a residual cc with `worst_spec = <spec>` and `worst_reason` naming the litmus test
- **AND** the residual SHALL persist until either the code is corrected or an explicit OpenSpec amendment lands

### Requirement: Staleness detection via timestamp and content hash

Every authoritative artefact SHALL be observable for staleness through two independent signals: a wall-clock timestamp (`last_verified`, `last_updated`, or git mtime) and a content hash (sha-256 over the artefact body). Either signal alone is insufficient — a re-verified cheatsheet may carry the same content hash even though its provenance has been re-checked; a drifted artefact may carry a stale hash even though git mtime is fresh.

#### Scenario: Cheatsheet beyond staleness window
- **WHEN** `last_verified` is older than the project staleness threshold (default 180 days)
- **THEN** the freshness check SHALL emit a warning naming the cheatsheet
- **AND** the warning SHALL be non-blocking (CRDT principle: warnings, not errors)

#### Scenario: Content drift without timestamp update
- **WHEN** an artefact's content hash changes
- **AND** its `last_verified` or `last_updated` field is unchanged
- **THEN** the freshness check SHALL flag the artefact as "drifted-without-acknowledgement"
- **AND** the next maintainer SHALL update the timestamp after re-verifying the citations

#### Scenario: Timestamp bump without content change
- **WHEN** a re-verification updates `last_verified` but the content hash is unchanged
- **THEN** this is the expected path
- **AND** the freshness check SHALL clear the staleness warning for the affected window

### Requirement: Convergence evidence bundles

Every claim about convergence between code and spec SHALL be backed by an **evidence bundle**: a structured artefact that names the commit, the test runs that passed, and the trace annotations that link the two. Evidence bundles are append-only and are referenced by the CentiColon signature log.

#### Scenario: Evidence bundle structure
- **WHEN** an evidence bundle is produced
- **THEN** it SHALL contain at minimum: `commit_sha`, `test_run_id`, `traces` (list of `@trace spec:<name>` annotations covered), `litmus_results` (list of `{ test_id, status }`), and `produced_at`
- **AND** the bundle SHALL be written to `target/convergence/evidence-bundle.json`

#### Scenario: Signature references evidence
- **WHEN** a CentiColon signature is appended to `target/convergence/centicolon-signature.jsonl`
- **THEN** the signature SHALL include the `evidence` field pointing to the bundle that produced it
- **AND** the dashboard SHALL surface the same `evidence` field for every row

#### Scenario: Missing evidence is reported as residual
- **WHEN** a spec claims convergence but no evidence bundle exists or the bundle does not reference the spec's litmus tests
- **THEN** the convergence claim SHALL be treated as unfounded
- **AND** the dashboard SHALL count the unfounded claim as residual cc rather than earned cc

### Requirement: Provenance is mandatory for every authoritative artefact

Specs, cheatsheets, and methodology files SHALL each declare provenance: at least one external high-authority URL (vendor, standards body, recognised community project) and a `Last updated:` date. Artefacts without provenance MUST NOT be cited as sources of truth.

#### Scenario: Cheatsheet without provenance
- **WHEN** a cheatsheet lacks a `## Provenance` section with at least one URL
- **THEN** any spec citing that cheatsheet under `## Sources of Truth` SHALL emit a validation warning
- **AND** the warning SHALL persist until the cheatsheet is retrofitted with provenance

#### Scenario: Spec without Sources of Truth
- **WHEN** a new spec is added without a `## Sources of Truth` section listing at least one cheatsheet
- **THEN** `openspec validate` SHALL emit a warning
- **AND** existing pre-convention specs are exempt until a retrofit sweep lands

### Requirement: Integration with downstream observability surfaces

This spec SHALL be the upstream input for every observability surface that reports on convergence. Downstream surfaces (dashboards, litmus reports, evidence bundles, trace indexes) SHALL cite this spec by name and SHALL respect the authority hierarchy, CRDT semantics, and divergence-resolution rules defined here.

#### Scenario: Dashboard cites this spec
- **WHEN** `docs/convergence/centicolon-dashboard.md` is regenerated
- **THEN** it SHALL include a pointer back to `openspec/specs/knowledge-source-of-truth/spec.md`
- **AND** the dashboard SHALL describe itself as a read-only projection of this spec's evidence semantics

#### Scenario: Observability event includes source-of-truth field
- **WHEN** a log event reports a convergence measurement (coverage, staleness, drift)
- **THEN** the event MAY include `source_of_truth = "knowledge-source-of-truth"` to signal which epistemology the measurement applies to
- **AND** future surfaces interpreting the event SHALL fall back to that spec for interpretation rules

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:knowledge-source-of-truth-shape`

Gating points:
- Cloned repository contains ONLY `openspec/vendor/` (no `vendor/debug/`)
- Developers run `/startup` or `/bootstrap-readme` to populate vendored knowledge
- All tools and agents are available after bootstrap; no runtime downloads needed
- Clean clone works offline (no network calls before bootstrap)
- Bootstrap completes within X seconds on typical hardware
- Vendored knowledge is read-only from developer perspective; updates come from CI/CD
- The spec.md body asserts the authority hierarchy `code > specs > cheatsheets > docs`
- The spec.md body asserts CRDT semantics (monotonic, commutative, idempotent, tombstoned removal)
- The spec.md body asserts spec-vs-code divergence resolution (code is wrong; spec wins)
- The spec.md body asserts the evidence-bundle structure (commit, traces, litmus results)

Falsifiable checks (the litmus runner SHALL fail the spec-shape test if any of these are missing):
- `grep -F 'code > specs > cheatsheets > docs' openspec/specs/knowledge-source-of-truth/spec.md`
- `grep -F 'CRDT-inspired monotonic convergence' openspec/specs/knowledge-source-of-truth/spec.md`
- `grep -F 'Spec-vs-code divergence resolution' openspec/specs/knowledge-source-of-truth/spec.md`
- `grep -F 'Convergence evidence bundles' openspec/specs/knowledge-source-of-truth/spec.md`
- `grep -F 'Staleness detection' openspec/specs/knowledge-source-of-truth/spec.md`

## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns
- `cheatsheets/runtime/cheatsheet-crdt-overrides.md` — CRDT semantics this spec derives its convergence model from (Wikipedia CRDT entry; Shapiro et al., INRIA, 2011)
- `cheatsheets/observability/cheatsheet-metrics.md` — metric definitions and aggregation patterns for evidence bundles
- `openspec/specs/methodology-accountability/spec.md` — CentiColon residual proximity boundary (peer spec for evidence accounting)

External provenance for the epistemology sections:

- Conflict-free replicated data type (Wikipedia) — <https://en.wikipedia.org/wiki/Conflict-free_replicated_data_type>
- Shapiro, Preguiça, Baquero, Zawirski, "A comprehensive study of Convergent and Commutative Replicated Data Types", INRIA 2011 — <https://hal.inria.fr/inria-00609399v2/document>
- **Last updated:** 2026-05-14

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:knowledge-source-of-truth" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
