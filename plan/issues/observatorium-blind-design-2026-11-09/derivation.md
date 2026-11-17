# Backward derivation: level-5 obligations → observables → GQM → data → views

Source: `input/level-5-phd.md` only. Obligation labels `L5-xx` are mine; they
name claims the document makes or obligations it says the project carries.
Where the document cites a repository footnote I record the footnote number
as an opaque label (e.g. `[^9]`) and do not open it.

Reader viewpoints (GQM "viewpoint"): **R1** non-technical reader (is this
project getting better, honestly?); **R2** technical reviewer (can I audit
the claim?); **R3** the project itself (what regressed?).

## 0. Inventory of obligations in the document

| ID | Obligation / claim (as written) | Kind | Source lines |
|---|---|---|---|
| L5-01 | Every obligation carries a stable identifier; a gate refuses missing or duplicate IDs, tombstoned specs included | requirement + gate | 17–19, 95, [^1][^42] |
| L5-02 | Obligation state is one of a seven-element chain `absent<declared<traced<pos_tested<neg_tested<runtime_obs<evidence_bundled` | model | 21 |
| L5-03 | Order is componentwise after aligning IDs and tombstones; a renamed coordinate is a different lattice | model hypothesis | 38–41 |
| L5-04 | `refine` is idempotent (claimed); monotone and inflationary are tested generatively over a committed rule set, not every live validator | claim + test | 49–51, 83–93, [^41] |
| L5-05 | Validator stability (`refine(x)=x`) is distinct from completion | model | 74–75 |
| L5-06 | The comparison bar `B_v` is fixed within a release; raised only by operator decision; automation must not self-escalate | governance | 76–81, [^8] |
| L5-07 | Release-over-release non-increase of `d_v` (non-regression) is the mechanically checkable release rule; `d_*=0` is not claimed | release rule | 101–121 |
| L5-08 | Residual `R_S(x)=Σ w_i(1−C_i(x))` over declared, unmet obligations; unit, scope and evidence policy fixed across a comparison | measurement contract | 125–137 |
| L5-09 | New obligations, retirements, evidence invalidation must be reported explicitly, never called progress | reporting rule | 136–137, 195–196 |
| L5-10 | Conditional cycle bound: no regression + decrease within K cycles ⇒ zero in ≤ K·R(x0) cycles; not a wall-clock bound | conditional theorem | 139–143 |
| L5-11 | Grader currently reports an unweighted count at the positive-test bar while the methodology declares weighted policy | known divergence | 145–148, [^47][^15] |
| L5-12 | Regression reporter is advisory, stores an untracked per-checkout baseline | known gap | 148–149, [^48] |
| L5-13 | Grader selects by test name and digest, not required platform; spec-digest check conditional; does not match implementation inputs | known gap | 155, [^47] |
| L5-14 | Scenario candidates shared at requirement level; invariants extracted separately from grading | known gap | 155–156, [^49][^50] |
| L5-15 | Tombstone ⇒ regime Broken ⇒ score not comparable with previous run | instrument | 195, [^44][^45] |
| L5-16 | Cross-release comparison needs aligned obligation set and weights; ratio alone cannot repair scope change | rule | 190–196 |
| L5-17 | Each workstream i has its own residual d_i; residuals are not samples of a common distribution; compare only aligned measurements; retain counterexamples and retractions as first-class outcomes | reporting rule | 216–224 |
| L5-18 | Strong-law citation withdrawn; iteration practice is an empirical track record, not an a.s. guarantee | retraction | 237, 304 |
| L5-19 | No Galois connection; closure proves neither adequacy of the obligation set nor universality over executions | negative claim | 308–332 |
| L5-20 | Credit means reaching the configured evidence bar, not the top of the lattice; a passing CI check ⇒ pos_tested only | semantics | 328–330, [^51] |
| L5-21 | CentiColon is a bounded ranking function with separately reported denominator and residual; not a measure; not a probability; no complement rule | semantics | 334–359 |
| L5-22 | Shell scorer supplies weights over CI check names; the rich multiplier/credit/cap/penalty table is not implemented | known gap | 361, [^27][^15] |
| L5-23 | The committed dashboard is a historical 890/990 snapshot, not a measurement of this release | known defect | 361, [^28] |
| L5-24 | Methodology/codebase complexity ratio < 0.15; red flag at 5000 lines of CI validators; no enforcing check | unenforced constraint | 364–365, [^30] |
| L5-25 | Plan ledger is a CRDT: G-sets for packets/events, LWW registers, fold in (ts, filename) order; commutativity and idempotence tested by name; associativity not named | claim + partial test | 369–395 |
| L5-26 | Status field: monotone join over closure rank, LWW tiebreak, descent only under `falsified` | model | 397–401 |
| L5-27 | Retracted CRDT claim (seen-set dedup); semantic merge typed as cache; claim registry holds strength "external analogy" until property tests exist | provenance | 403–407 |
| L5-28 | Versioning document's semantics for two of four components are false vs. the live temporal scheme | documentation defect | 409–410 |
| L5-29 | Unknown-event intake is the escape hatch of the defensible claim | model | [^40] |

## 1. Obligation → what must be observable

| ID | To verify it, a reader must be able to see… |
|---|---|
| L5-01 | The set of IDs at the release; count; duplicates = 0; tombstoned IDs listed; the gate's last verdict |
| L5-02 | For each ID, its current rung and its configured bar; distribution of rungs |
| L5-03 | Per release: IDs added, retired (tombstoned), renamed; whether the lattice is comparable to the previous release |
| L5-04 | Names and last results of the three property tests; a plain statement that they cover a committed rule set, not live validators |
| L5-05 | Whether the last refine run was a fixed point (stable) and, separately, the count of unmet obligations |
| L5-06 | The bar value per release; a change log of bar raises, each with "operator decision" provenance; zero raises by automation |
| L5-07 | Series of `d_v` (or `R_S`) per release with regression flags; the floor so far; explicit "zero not claimed" |
| L5-08 | For each release: S (scope), weights, the C_i evaluations, the sum; the policy version in force |
| L5-09 | Separate ledgers: new obligations, retired, invalidated evidence — each per release, never folded into the score delta |
| L5-10 | Cycles since last strict decrease; current R; the K parameter if declared; the implied bound; marked as conditional |
| L5-11 | Both numbers side by side: unweighted count at pos-test bar and (if ever computed) weighted; labelled as different projections |
| L5-12 | Whether a durable baseline exists; the baseline's release and digest |
| L5-13 | Per obligation × platform: attributed / not attributed; spec digest matched / unchecked |
| L5-14 | Count of scenarios with requirement-level (shared) candidates vs. scenario-specific; invariants listed separately |
| L5-15 | The regime (Comparable / Broken + reason) per release; breaks drawn as breaks in series |
| L5-16 | Scope alignment table between two chosen releases: common IDs, dropped, added; score recomputed on the intersection |
| L5-17 | Per-workstream residuals, each with its own scope and controls; a retractions/counterexamples list |
| L5-18 | A "claims withdrawn" register with date and reason; iteration cadence shown as a record, not a guarantee |
| L5-19 | A standing disclaimer attached to every closure figure; the adequacy question stated as open |
| L5-20 | Per obligation: bar vs. reached rung; a figure for "credited at bar" distinct from "at top of lattice" |
| L5-21 | Denominator and residual always shown as two numbers; the ratio shown only alongside them; never as a probability or "confidence" |
| L5-22 | The weight table in force (check name → weight) and a flag that the rich policy is not implemented |
| L5-23 | Every figure stamped with the release and build time it measures; stale snapshots impossible by construction |
| L5-24 | Line counts: validators total, methodology total, codebase total; the ratio; the 5000-line flag; "unenforced" label |
| L5-25 | Names of the fold property tests and last results; the untested property (associativity) listed as untested |
| L5-26 | Count of `falsified` descents per release (the escape hatch in use), and lateral/terminal moves |
| L5-27 | Claim registry: claim, strength, what would raise it; retracted claims listed |
| L5-28 | Version displayed with its live meaning (date-based); doc/live mismatch flagged while it persists |
| L5-29 | Unknown-event intake count per release and how many were later classified |

## 2. GQM: goals, questions, metrics

**G1 (R1): Characterise project progress, honestly, from the viewpoint of a
non-technical reader.**

- Q1.1 Is the declared residual going down release over release? → M1 `R_S` per release with regime; M2 regression flag (bool) per release; M3 releases since last strict decrease.
- Q1.2 How much of what the project promised itself has evidence? → M4 credited-at-bar count / denominator (both numbers); M5 rung histogram.
- Q1.3 Did the goalposts move? → M6 obligations added / retired / renamed per release; M7 bar raises per release with provenance.
- Q1.4 What did the project retract? → M8 retraction register entries per release.

**G2 (R2): Evaluate auditability of each published figure from the viewpoint
of a reviewer.**

- Q2.1 Can I trace this number to a release and a spec state? → M9 release tag, build time, spec digest per figure.
- Q2.2 Is the comparison between two releases valid? → M10 regime; M11 intersection score on aligned scope.
- Q2.3 Which evidence rung does a "pass" actually establish? → M12 per-obligation (bar, reached).
- Q2.4 Which hypotheses of the convergence story are discharged? → M13 property-test ledger (name, status, scope); M14 open-hypothesis list (progress premise, metric, platform attribution, live validators).
- Q2.5 Is the validation system itself under control? → M15 complexity ratio and 5000-line flag.

**G3 (R3): Monitor regressions and instrument gaps from the project's own
viewpoint.**

- Q3.1 Which obligations lost credit? → M16 per-obligation delta (release n−1 → n).
- Q3.2 Which platforms lack attribution? → M17 obligation × platform matrix.
- Q3.3 How many CRDT/ledger property tests are green and which property is untested? → M13 subset.
- Q3.4 Is the escape hatch (falsified descents, unknown-event intake) being used? → M18 counts.

## 3. Metric → data needed

| Metric | Data fields (per release unless noted) | Origin (assumed; see questions) |
|---|---|---|
| M1, M2, M3, M10 | `release`, `built_at`, `residual`, `denominator`, `earned`, `regime{kind, reason}`, `policy_version` | grader output (Q4) |
| M4, M5, M12, M16 | per obligation: `id, kind, bar, reached, weight, tombstoned, workstream` | obligation registry (Q1, Q2) |
| M6 | diff of ID sets between consecutive releases; rename map | registry diff computed at snapshot time |
| M7 | `bar_changes[]: {release, from, to, decided_by:"operator", ref}` | hand-maintained ledger file (no automation source) |
| M8, M14 | `claims[]: {id, statement, strength, status∈{asserted,withdrawn,open}, since, what_would_discharge}` | hand-maintained claim register |
| M9 | `release, built_at, spec_digest, snapshot_digest, generator_version` | snapshot builder |
| M11 | computed from two releases' obligation lists | snapshot builder |
| M13 | `property_tests[]: {name, property, scope, status, last_run}` | test report (Q9) |
| M15 | `loc: {validators, methodology, codebase}` | line counter at snapshot time (Q8) |
| M17 | `platforms[]`, per obligation `attributed_platforms[]` | grader (Q5) — likely absent |
| M18 | `falsified_descents`, `unknown_events_in`, `unknown_events_classified` | ledger export |

## 4. Views needed

| View | Readers | Serves |
|---|---|---|
| V1 Front page "Is it getting better?" | R1 | Q1.1–Q1.4: residual series with regime breaks; two-number credit; goalpost ledger; retraction count |
| V2 Obligations table (filter by kind, rung, workstream, platform) | R2, R3 | Q1.2, Q2.3, Q3.1, Q3.2 |
| V3 Release page (one per release) | R2 | Q2.1, Q2.2: stamp, digests, diff from previous, aligned-scope score |
| V4 Hypotheses & claims | R2, R1 | Q2.4, Q1.4: what is proved, tested, assumed, withdrawn |
| V5 Instrument health | R3, R2 | Q2.5, Q3.3, Q3.4 |
| V6 Methodology glossary ("what a CentiColon is and is not") | R1 | the no-probability rule; bar vs. top |

## 5. Obligations that are unmeasurable or ambiguous as written

These are findings about the document, not about any dashboard.

1. **L5-07 `d_v` has no definition.** The document itself says `d` is only
   ever evaluated at `(I_v, T_v)` and is "unspecified". The only concrete
   candidate is `R_S`. Until the project says "d_v := R_S at policy P", the
   release rule "non-increase of d_v" is unmeasurable. The dashboard must
   display `R_S` and say it is a *proposed* instantiation.
2. **L5-08 weights `w_i` are "positive integer weights" but the grader is
   unweighted (L5-11).** Two residuals exist (weighted policy, unweighted
   count) and the document calls them non-interchangeable. Which one is the
   release rule evaluated on? Ambiguous; both must be shown, neither may be
   called "the" score.
3. **L5-10 K is undeclared.** The cycle bound is stated conditionally on a K
   nobody has fixed. Without K the bound cannot be displayed as a number;
   only "cycles since last decrease" can.
4. **L5-06 "operator decision" has no evidence form.** What artefact proves a
   bar raise was operator-approved and not automated? Without a defined record
   the obligation is auditable only by absence (no raise occurred).
5. **L5-13 "required platform" is undefined per obligation.** The gap is
   named, but the set of required platforms per obligation is not stated
   anywhere in the document, so "attributed to every required platform" has
   no denominator.
6. **L5-16 "aligned weights" across releases** — alignment of the ID set is
   mechanical; alignment of *weights* when the policy changes has no rule
   ("no general normalisation rule is established"). Any cross-release view
   must restrict to releases under the same policy version.
7. **L5-20 the configured bar per obligation** — the document says credit is
   reaching the configured bar, but whether bars are per-obligation, per-kind,
   or global is not stated. The design assumes per-obligation with a default.
8. **L5-24 "complexity"** is given as a ratio of two undefined quantities; the
   red flag uses lines of code. The only measurable reading is LOC, which the
   rule does not actually say. Flag: measurable only under an interpretation.
9. **L5-17 "workstream residuals"** — accessibility, marketing, dashboards,
   support are named as having "their own d_i" but no scope or obligation
   membership for those workstreams is defined; nothing can be measured.
10. **L5-05 stability** is computable in principle (`refine(x)=x`) but the
    document gives no exported signal of "last refine run was a fixed point".
    Assume one can be emitted (Q2); otherwise unmeasurable.
11. **L5-29 unknown-event intake** is named as the escape hatch but no count
    or classification record is described. Measurable only if the ledger
    exposes it.
12. **Three rungs have no public witness.** `runtime_obs` and
    `evidence_bundled` require artefacts the document never describes as
    exportable; `traced` requires a trace index. A public dashboard can show
    these rungs as claimed by the grader but cannot let a reader verify them.
    This should be disclosed on the page.
13. **Positive language risk in L5-21.** "89% closed" is explicitly not an 11%
    chance of defect; yet the ratio earned/denominator is the most natural
    headline. The obligation forbids an interpretation without forbidding the
    display; the design resolves it by always printing the two integers and
    the ratio as a secondary, labelled figure.

## 6. Trace summary

Every view in `design.md` carries a `serves:` line listing the L5 IDs and
metrics above. Views without a trace are marked *designer's addition*. The
count of L5 obligations with at least one view: 29/29; with a fully
measurable metric under the stated assumptions: 16/29; unmeasurable or
ambiguous as written: 13 (listed in §5).
