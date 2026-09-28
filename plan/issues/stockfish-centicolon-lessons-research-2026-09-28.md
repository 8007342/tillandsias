# Modern Stockfish lessons for CentiColon and Lua evidence

Packet: 1453-p9gb. Author: Codex, macuahuitl. Investigated 2026-09-28 UTC
(operator request 2026-09-27 local date). Branch: work/1447-9sne.
Related design: [CentiColon transient-work review](centicolon-transient-work-scope-research-2026-09-27.md),
order 1447-9sne. Status: source investigation complete; recommendations
remain proposed. No engine tournament, production change, policy experiment
or enforcement bar raise was performed.

## Finding

Borrow Stockfish's separation of evaluation, search and experimental
validation. Keep Tillandsias correctness evidence distinct from predictions
about which work to attempt. The latter may learn and revise its estimates;
the former must name reproducible, applicable evidence. Neither centipawns
nor Fishtest supply a theorem that an evolving software project reaches
zero residual correctness debt.

The pure/observing Lua split is valuable, but the demonstrated scenario,
provenance and platform over-crediting is principally an evidence-model
problem. A pure grader can produce the same wrong credit every time.
There are additional cache-key/snapshot concerns worth testing separately;
see the parent review's purity section.

## Upstream baseline and source boundaries

GitHub's official releases/latest API returned **sf_19**, published
2026-09-05T08:33:17Z. The tag resolves to commit
`edb0d9db6731067ec50ce619ff372b463bc4dd5d` (commit date 2026-09-05).
WDL_model master resolved to
`04c11f08293667d1394000034549d9d880441934` (2026-09-27).
Commands: `gh api repos/official-stockfish/Stockfish/releases/latest`,
`gh api repos/official-stockfish/Stockfish/commits/sf_19`, and
`gh api repos/official-stockfish/WDL_model/commits/master`.
Source was read at the sf_19 tag; links below pin its resolved commit.
Fishtest documentation is a dated 2026-09-28 web observation, not a claim
about a pinned Fishtest server deployment.

[Stockfish 19's announcement](https://stockfishchess.org/blog/2026/stockfish-19/)
describes SFNNv16, new pawn-pair features, removal of redundant threat
features and the secondary network, quantization-aware training, universal
binaries, platform additions, and stricter position/command validation.
The earlier
[Stockfish 18 announcement](https://stockfishchess.org/blog/2026/stockfish-18/)
describes threat inputs, shared network-weight memory, correction history,
and reproducible training recipes. These are release-specific developments;
dual-network routing should not be described as the current SF19 design.

The project reports strength gains under its match conditions. Those claims
are not measurements of any Tillandsias benefit. Universal CPU dispatch
and NNUE training are informative context, not a reason to add a neural
scorer or new platform machinery to this design.

## Transfer assessment

### 1. Calibrated evaluation: useful only as a separate prediction layer

Upstream fact: the
[WDL model](https://github.com/official-stockfish/WDL_model/blob/04c11f08293667d1394000034549d9d880441934/README.md)
fits game outcomes from Fishtest data. Evaluation and material remaining
condition the win/draw/loss estimates. Since SF17 the displayed 1.0 is
normalized to the internal evaluation associated with a 50% win rate at
that material level under the model. It is not a universal promise about
human games, nor a simple material count.

Tillandsias proposal: keep residual cc as an auditable accounting quantity.
Separately estimate outcomes such as a candidate's likelihood of catching
an escaped defect, time to valid closure, or chance of completing within a
budget. Condition these on obligation family, evidence tier and platform;
publish the dataset window, model version and calibration error. No such
model or probability is established by this investigation.

Acceptance: any later model must outperform a simple declared baseline on
held-out release/failure-family cohorts, report reliability by cohort, and
handle missing/censored outcomes explicitly. It cannot award cc or turn
an unobserved mandatory platform into a pass. Do not fit and validate on
different fragments describing the same underlying defect.

### 2. Typed cache entries: adopt the semantics, reject approximate authority

Upstream fact: Stockfish's
[TTData](https://github.com/official-stockfish/Stockfish/blob/edb0d9db6731067ec50ce619ff372b463bc4dd5d/src/tt.h)
separates value, static evaluation, depth and bound type. Its own comments
explicitly acknowledge racy/non-atomic access and possible collisions.
[Replacement](https://github.com/official-stockfish/Stockfish/blob/edb0d9db6731067ec50ce619ff372b463bc4dd5d/src/tt.cpp)
considers depth and age, and probes compare a shortened key within a cluster.
The implementation deliberately trades some correctness risk for chess
strength and speed. Do not copy that tradeoff into closure evidence.

Tillandsias proposal: a cached result carries its actual evidence level,
subject and applicability rather than one Boolean that means both traced
and verified. An upper/lower chess bound is not literally a software-test
bound; the transferable point is preserving what the result establishes.
Use full content identities and immutable manifests, explicit validator
and policy versions, complete dependencies and atomic publication. A cache
miss, eviction, timeout, missing dependency or conflict cannot become pass.

Local seam: PredicateRegistry currently memoizes a Boolean by name/argument
and validates read paths' content digests. Re-registering a name does not
clear the old entry; digests are gathered after evaluation. These source
observations justify tests for evaluator replacement and files changing
during a read, not a claim that either path was exploited experimentally.
Also decide how a cached structured result is replayed: the current
extractor exposes JSON through log_info, while a memo hit returns a Boolean.

Acceptance: cached and uncached structured verdicts, reasons and manifests
are identical; changing source/runtime/policy/any dependency invalidates
reuse; missing and newly discovered files participate in the manifest;
an interleaved write cannot authenticate bytes the predicate never saw.
Immutable observations may be graded purely; observing a live system is
still an acquisition step with its own validity conditions.

### 3. Incremental evaluation: adopt after proving equivalence

Upstream fact: the
[NNUE accumulator](https://github.com/official-stockfish/Stockfish/blob/edb0d9db6731067ec50ce619ff372b463bc4dd5d/src/nnue/nnue_accumulator.h)
tracks computed state, dirty changes and incremental updates; accumulator
caches support refresh without rebuilding everything from scratch.

Tillandsias proposal: retain per-obligation evidence and reverse dependency
maps. Re-evaluate obligations affected by changed spec, implementation,
binding, runner, policy or observation inputs. This could reduce repeated
whole-corpus work without changing the scoring rule. Runtime observations
need explicit freshness/applicability, not just unchanged source bytes.

Acceptance: for a corpus of edits including rename, deletion, new files,
symlink changes, toolchain changes and policy changes, incremental output
must equal a full recomputation byte-for-byte. Benchmark cold, warm and
one-input-invalidated paths on Linux/macOS/Windows separately. No universal
latency target is inferred from Lua or NNUE. Prefer whole-subject identity
until finer dependency completeness is demonstrated.

### 4. Bounded search and correction history: adopt for selecting work

Upstream fact:
[search.cpp](https://github.com/official-stockfish/Stockfish/blob/edb0d9db6731067ec50ce619ff372b463bc4dd5d/src/search.cpp)
uses iterative deepening, budget/stop conditions, quiescence search and
correction history; it keeps unadjusted static evaluation separate from
history-adjusted evaluation. Its search also uses selective pruning.

Tillandsias proposal: rank promising obligations, begin with cheap evidence,
then deepen verification on a declared schedule. A deterministic assertion
failure stops acceptance immediately. A shallow pass leaves required deeper
checks pending. If a repair exposes another failure in its declared causal
scope, verify that neighborhood before claiming stabilization. Bound this
work; exceeding the budget reports an unresolved condition rather than
silently increasing the operator-approved scan bar.

Correction history suggests maintaining a versioned history of which
failure families, files and regimes repeatedly escape guards. Use that to
prioritize verification, with decay and provenance. Do not use learned
corrections to adjust earned cc, erase counterexamples or modify closure
thresholds. Keep a nonzero exploration allocation and mandatory critical
checks so successful early heuristics cannot starve unseen failure classes.

Acceptance: replay the same held-out workload and budget under the existing
selector and the proposed selector. Report earlier detection, missed
failures, unresolved work and cost. A faster policy that skips a mandatory
assertion is inadmissible. Chess search pruning is an optimization of play,
not permission to prune correctness requirements.

### 5. Fishtest: adopt controlled comparisons, not chess's outcome model

Upstream fact:
[Fishtest mathematics](https://official-stockfish.github.io/docs/fishtest-wiki/Fishtest-Mathematics.html)
describes a pentanomial match model, generalized sequential probability
ratio testing, normalized Elo bounds, parameter tuning, and detection of
statistically anomalous workers. Its assumptions concern game-pair outcome
distributions, not arbitrary software-engineering events.

The
[test workflow](https://official-stockfish.github.io/docs/fishtest-wiki/Creating-my-first-test.html)
separates short and long time controls, provides different testing modes
for changes and simplifications, asks for branch signatures, and retains
review after a test passes. It also documents SPSA for parameter tuning.
The
[FAQ](https://official-stockfish.github.io/docs/fishtest-wiki/Fishtest-FAQ.html)
discusses repeated attempts, test history and the assumption behind worker
residual comparisons.

Tillandsias proposal: compare one candidate policy with a fixed baseline on
the same workload, host class, toolchain, artifact and budget. Counterbalance
execution order to expose warming/load effects. Predeclare the endpoint,
meaningful effect/noninferiority margin, decision rule and cost ceiling.
At the ceiling without adequate evidence, report inconclusive. Preserve
failed trials and count repeated attempts; do not rerun until a pass.

Start with paired measurements and a held-out corpus. Sequential tests are
a later option only after choosing and validating a model for the actual
endpoint. The software task need not have five outcomes, and skipped or
missing verification is not a chess draw. Do not apply Elo or the chess
pentanomial likelihood to task completions by analogy.

Stratify operating systems and required runtime regimes. Fishtest's worker
anomaly comparison is useful inspiration only within comparable cohorts;
a Windows-specific failure must not be dismissed as an outlier because
Linux passes. If a host is quarantined, affected evidence becomes pending
revalidation and the observation remains in history.

SPSA may eventually tune scheduling coefficients under a stable benchmark.
Do not tune normative obligation weights or the pass threshold to improve
the measured closure score: that changes the objective. Add a learned or
tuned selector only after a simpler selector has a measured shortcoming.

### 6. Strict validation and limited exact answers: adopt explicit domains

Upstream fact: SF19 reports stricter input validation in its release notes.
Its search probes tablebases only under explicit applicability conditions
(piece count, castling/rule context and probe success). A heuristic score
and a successfully applicable specialized result are different objects.

Tillandsias proposal: validate evidence envelopes before scoring; refuse
malformed IDs, missing subject identity, contradictory status and incomplete
regime declarations. Preserve narrow, mechanically decidable contracts where
exhaustive tests or proofs are possible. Label their precise domain. They
do not turn finite tests of a distributed runtime into universal proof.

Acceptance: malformed evidence cannot improve a score; incomplete evidence
remains visible; proof/model-check artifacts name model, assumptions,
validator and subject. The actual implementation must still satisfy the
model-to-code correspondence. Tablebases are inspiration for bounded exact
subproblems, not a claim that our current fixtures constitute one.

## Concrete proposed architecture

```
scoped obligations + fixed evidence policy
                    |
                    v
Observing acquisition -> immutable, attributable evidence
                                      |
                                      v
                           pure grade + exact cache
                                      |
                        per-obligation compare
                           /                 \
               hard acceptance          residual dashboard

failure/cost history -> revisable work selector -> next scoped experiment
                                    |
                       baseline/candidate comparison
```

The historical evidence ledger can grow monotonically while current
applicability is invalidated by a counterexample, changed inputs or age.
Do not merge those two meanings of monotonicity. A complete metric reports
new discoveries and lost credit honestly, even when they increase R.

Proposed evidence envelope: schema and policy IDs, scope/obligation/scenario
IDs, assertion ID and type, runner/predicate/runtime digest, implementation
artifact/tree identity, full dependency manifest, spec/binding digests,
required regime and observed environment, unique run identity, outcome and
failure reason, captured artifacts, and explicit supersession/applicability.
Use a digest of this canonical envelope as a reference. Hashing makes
artifacts identifiable; it does not authenticate a dishonest producer or
prove semantic adequacy. The trusted acquisition boundary remains explicit.

The current seven-state display is at most a derived view of independent
evidence facts. Runtime observation is not automatically a negative test;
bundling an artifact is not automatically stronger behavioral evidence.

## Progressive experiment program

This extends the parent six-stage design, without filing implementation
orders before the operator chooses the program.

| Experiment | Existing seam | Required falsifier/control | Decision enabled |
|---|---|---|---|
| A. Evidence attribution | 1395-88tp static/observed graders | Sibling scenarios, wrong/missing subject, cross-platform pass masking fail, mixed pass/skip, malformed/conflicting records | Whether any credit is safe to pilot |
| B. Pure replay and cache | PredicateRegistry and 1437-v3gb input-memo work | Replace predicate source; edit dependency during read; add/delete dependency; change policy/runtime; compare uncached structured result | Whether memoization can preserve the evidence contract |
| C. Preventive closure | 1395-64r7 pilot plus invariant/platform examples | Actual pre-fix or semantic mutant fails for the intended reason; corrected behavior passes in every required regime | Whether a transient fix yields measurable prevention |
| D. Incremental scoring | Extractor manifest and reverse dependencies | Full recomputation is the oracle across adversarial edits | Whether gate cost can fall without weaker evidence |
| E. Work selection | 1395-miwn and coordinator skills | Fixed-budget paired baseline/candidate runs; held-out families; retain misses, repeats and inconclusive results | Whether recurrence history improves selection |
| F. Release claims | 1395-ue3i, signature/dashboard and website | Reproduce the release score from a clean checkout and immutable artifacts | Whether public claims reflect shipped behavior |

A-C are prerequisites for enforcement, D is an optimization, E is research
into selection, and F communicates achieved results. A neural or probabilistic
selector is not required for any of A-D. No projected gain is reported as
an achieved one. Minimum work and falsifiers are specified; timing/error
budgets and adoption remain operator decisions informed by pilot results.

## Website language after BigPickle's refresh

Keep the centipawn inspiration but qualify its scope: chess engines use
evaluation to guide bounded search and evaluate changes empirically.
CentiColons count evidence-backed obligations under an explicit policy.
Neither score is a monotonic certificate of eventual success. Modern
Stockfish's calibrated WDL layer illustrates an optional future prediction
layer, not a probability interpretation of today's cc.

At inspection, website main was b4af7a7 with level pins v56.9.21.1; the
published Tillandsias release was v56.9.27.2. The website was not changed.
Once refreshed, cite released functionality separately from this proposed
design, identify the advisory ratchet, and distinguish validator stability
from R=0. Source-pure evaluation is a technical enabler, not the missing
strict-progress premise of a finite-time theorem.

## Verification and limits

- Official release and source references checked on 2026-09-28 UTC; only
  primary sources used for Stockfish claims. No Stockfish code copied into
  Tillandsias and no Python tooling added or run for this research.
- Parent counterexamples ran the checked-out Lua sources with in-memory
  fixtures; this research adds source inspection, not a sandbox audit.
- Cache hazards are source-reviewed hypotheses awaiting targeted runtime
  tests. Work-selection/calibration proposals are untested experiments.
- Coordinator baseline and Antigravity's verbatim position are retained in
  the merged parent document. Their proposed spec text remains an explicit
  unadopted proposal; no production grader, skill or methodology is changed.
- Research completion means this source investigation and proposed program
  are delivered. Parent design adoption and implementation remain open.
