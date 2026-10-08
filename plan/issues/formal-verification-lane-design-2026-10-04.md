# Formal verification lane — design note (2026-10-04)

Milestone packet: `1550-32d6`. OpenSpec change:
`openspec/changes/formal-verification-lane/`. Filed from yoga on work ref
`work/1550-32d6`, based on `origin/linux-next` 9dae9870b.

This note is written so that an agent with no access to the session that
produced it can continue the work. Everything the packets rely on is either
quoted here, measured here with the command that measured it, or cited to a
file in this repository or the sibling `tillandsias.org` checkout.

## 0. How to resume cold

1. Read §1 (what the operator ruled) and §10 (what the operator has NOT ruled).
2. Read §5. Two of the findings are measured defects that need no new tooling
   and can be worked today: `1550-8528` and `1550-a5jc`.
3. `tillandsias-plan status 1550-32d6` and its children (§11) say what is
   claimed. The dependency order is in
   `openspec/changes/formal-verification-lane/tasks.md`.
4. No Lean or Kani toolchain exists on any host yet. `1550-n4eb` builds the
   lane; nothing that needs Lean can close before it.
5. Nothing in this note was compiled by Lean or checked by Kani. The Lean text
   in §4 is statement shapes for review, labelled as such.

## 1. Operator direction (verbatim, 2026-10-04, yoga session)

The request that opened the work:

> we have some mathematical principles, in this project, in our methodology,
> baked into our tillandsias project, and somewhat documented in our
> ../tillandsias.org website, please take a look at the PROOF we're trying to
> achieve, using Monotonic Reduction of Uncertainty, to achieve convergence. I
> just heard there's a language called LEAN to proove mathematical forms. We
> recently introduced a LUA runtime and a CENTICOLONS metrics, see if that
> combined with LEAN programming language, is there something we could
> leverage from it?

Ruling R1 — where formal tools may live:

> Lean might be just for our builder infra, since we might want to verify our
> correctness wherever possible. Running in toolboxes and podman containers,
> should be transparent for all our linux hosts. Not on our user's runtime
> unless we justify its presence clearly.

Ruling R2 — the website follows:

> it might require updating ../tillandsias.org as well with the corresponding
> updates

Ruling R3 — durability and landing:

> I want long durable ./plan packets and specs, so even if this session ends
> and is irrecoverable, any other agent in any other harness should be able to
> take over and continue. File the ./plan and specs, use the linux-next remote
> integration branch

What the operator asked but did not rule on: Kani ("What's this KANI you
compare it to?"). Adopting Kani is therefore an open decision (§10), not a
ruling.

## 2. What the methodology claims today

The core principle is `philosophy.core_principle` in
`methodology/philosophy.yaml`: "Monotonic reduction of uncertainty under
verifiable constraints." The mathematics behind it is in
`methodology/math-foundations.yaml`, whose `thesis_defense_position` is the
whole claim:

> finite ordered convergence under declared validators: stable obligations
> form a finite lattice; evidence-improving transitions are checked for
> monotonicity; CentiColons are a bounded ranking function over that model;
> fixed points mean validator stability; and unknown-event intake is the
> escape hatch

The same file names what is NOT claimed: no Banach contraction
(`math.metric.contraction-not-claimed@v1`), no Galois connection
(`math.abstract-interpretation.evidence-abstraction@v1`), no probabilities
(`math.evidence.uncertainty-not-probability@v1`). `philosophy.yaml`
(`convergence_via_velocity.weak_vs_strong`) withdraws the strong law of large
numbers for dependent iterations, and its multi-version `statement` says that
non-increase of the residual reaches some floor `d_* >= 0` and does not by
itself prove `d_* = 0`.

The website's Level 5 page (`../tillandsias.org/docs/matrix/level-5-phd.md`,
site commit f6d57f5, pinned to stable v56.9.27.2) audits these claims, and
finding 1b27ef15 in `../tillandsias.org/issues.d/` (2026-09-28) retracted a
published overclaim of enforcement and fixed-point completion.

There are three layers, and every statement about "proof" must say which one
it is about:

| Layer | What it is | Evidence today |
|---|---|---|
| Model | Seven evidence states per obligation, the product lattice, the refinement operator, CentiColons as a ranking function, the ledger fold | Paper proofs on the Level 5 page; sampled property tests in `obligation_props.rs` over a three-rule fixture |
| Model to code | Whether `centicolon_function` and `Refiner` in `obligation.rs`, the fold in `fragments.rs`, and the Lua graders compute what the model says | Unit tests, property tests |
| Model to world | The progress premise (a residual drop within every K cycles), adequacy of the obligation set, whether a test tests what it claims | Empirical track record only |

A proof assistant strengthens the first layer, gives the second a reference to
be tested against, and does nothing for the third.

## 3. The tools

### 3.1 Lean 4

Lean 4 is a programming language and proof assistant. A theorem is a type; a
proof is a program of that type; a small trusted kernel refuses the file
unless every proof is complete. Its value is for universally quantified
statements ("for every state and every rule set"). It checks a MODEL written
in Lean, not the Rust or Lua.

- Site: https://lean-lang.org/ . Install is `elan`
  (`curl https://elan.lean-lang.org/elan-init.sh -sSf | sh`, installs to
  `$HOME/.elan`; read at https://lean-lang.org/install/manual/ on 2026-10-04).
- A project pins its toolchain with a `lean-toolchain` file and builds with
  `lake`.
- Mathlib (https://github.com/leanprover-community/mathlib4) is the community
  mathematics library. It carries the order theory this model needs
  (`Monotone`, finite products of lattices, finite sums). It is large;
  prebuilt object files come from `lake exe cache get`. Its size on this
  fleet's builder has NOT been measured — measuring it is an exit criterion of
  `1550-n4eb`. Whether to depend on it is open decision D2 (§10).
- Lean code is executable, so the model can print expected values.

Traps, each of which becomes a requirement on the lane:

1. `sorry` COMPILES. A proof containing `sorry` is accepted with a warning and
   depends on the axiom `sorryAx`. A lane that only checks the build's exit
   status is green for an unproved theorem. The lane must inspect the axioms
   each registered theorem depends on (`#print axioms`) and refuse anything
   outside an allowlist (`propext`, `Classical.choice`, `Quot.sound`).
2. A user-declared `axiom` proves anything. Same check.
3. `native_decide` trusts the compiler rather than the kernel. Not allowed by
   default.
4. A VACUOUS statement is proved trivially. A theorem with an unsatisfiable
   hypothesis, or about a model that does not match the code, is green and
   worthless. Proofs need no human review; STATEMENTS do. This is the same
   failure as a fixture that tests the world it builds.
5. The proof says nothing about a model the code does not implement. The
   vectors of `1550-88nf` are the only link, and they are tests.

### 3.2 Kani

Kani is an open-source bit-precise model checker for Rust
(https://github.com/model-checking/kani). A proof harness looks like a unit
test whose inputs are `kani::any()` — every possible value — and Kani either
proves the assertions for all of them or returns a concrete counterexample.
It also reports panics, arithmetic overflow and out-of-bounds access. It is
BOUNDED: loops and collections are unwound to a limit the harness sets, so it
proves "for all inputs up to this size".

Read at https://model-checking.github.io/kani/install-guide.html on
2026-10-04: supported hosts are `x86_64-unknown-linux-gnu`,
`x86_64-apple-darwin` and `aarch64-apple-darwin`; install is
`cargo install --locked kani-verifier` then `cargo kani setup`, which
downloads the Kani compiler and its dependencies under `~/.kani/`; the
requirement stated is Rust 1.58 or newer through `rustup`. There is no
aarch64 Linux or Windows host support, which matches a Linux-builder-only
lane.

Things to expect, not yet observed here:

- Harnesses sit behind `#[cfg(kani)]` and compile out of every normal build.
  The workspace may need `kani` declared as a known cfg so the
  `unexpected_cfgs` lint does not fail a `-D warnings` clippy run.
- Heap-heavy standard collections with string keys (the scorer uses
  `BTreeMap<String, _>`) are slow to model-check. The arithmetic should be
  factored into a function over fixed-size arrays or slices first.

### 3.3 How they compare

| | Checks | Covers | Blind to |
|---|---|---|---|
| proptest (in use) | the real Rust | random samples | inputs it did not draw |
| Kani | the real Rust | all inputs up to a size bound | sizes past the bound |
| Lean | a model written in Lean | all sizes | whether the code matches the model |

Neither tool appears anywhere in the repository today (a word search for
`kani`, `creusot`, `verus`, `prusti` and `cargo-mutants` outside `target/`
returned no project file on 2026-10-04; `zerocopy`, a dependency, uses Kani
in its own tree).

### 3.4 The hard-no-Python rule

`methodology.yaml` (`runtime_language_policy.tlatoani_hard_no_python.rule`)
forbids Python in runtime, harness and repository scripts. The lane's own
scripts are bash, Lua or Rust. Expected-value vectors are emitted by the Lean
model itself, not by a script in another language. Whether a third-party
tool's internals use Python is outside the rule's wording; the Kani install
page read on 2026-10-04 lists no Python requirement, and `1550-5sek` records
what the installed bundle actually contains.

## 4. The model and the theorem registry

### 4.1 The model, matching the Rust

- Evidence states: the seven-element chain `absent < declared < traced <
  positively_tested < negatively_tested < runtime_observed <
  evidence_bundled` (`formal_objects.obligation_state.ordered_values` in
  `methodology/math-foundations.yaml`; `ObligationState` in `obligation.rs`).
- A spec state over `n` obligations is a function from obligation index to
  evidence state, ordered componentwise (`SpecState` and its `PartialOrd`).
- A rule is `(id, to, applies)`: when `applies(state)` holds, obligation `id`
  is raised to at least `to` (`Rule`).
- One step applies every rule against the OLD state and never lowers a
  component (`Refiner::step`). `refine` iterates `step` to a fixed point
  (`Refiner::refine`).
- An obligation has a weight and a bar (`Weights`: `(u64, ObligationState)`).
  It is earned when its state is at or above its bar. Tombstoned obligations
  leave both the numerator and the denominator, and the score is then marked
  `Regime::Broken` (`centicolon_function`).

### 4.2 Theorem registry

Each row is a statement to be proved in Lean, with the methodology check it
discharges (`validation_program` in `methodology/math-foundations.yaml`).
Names are proposals; the registry file of `1550-n4eb` is the authority once
it exists.

Refinement (`1550-7qz6`):

| Id | Statement | Discharges |
|---|---|---|
| L1 `step_inflationary` | for every rule set and state, `x <= step x` | — |
| L2 `step_monotone` | if every rule predicate is upward closed (`x <= y` and `applies x` imply `applies y`), `step` is monotone | `allowed_evidence_transitions_are_monotone` |
| L3 `non_monotone_witness` | the committed wrong model (`non_monotone_rules` in `obligation_props.rs`: raise `req-b` when `req-a == Declared`) is not monotone, with the concrete pair | negative control for L2 |
| L4 `chain_height` | a strictly increasing chain of states over `n` obligations has at most `6n` strict steps | `product_order_is_componentwise` |
| L5 `iterate_stabilises` | iterating an inflationary `step` reaches a fixed point after at most `min(6n, number of rules)` strict steps | fixed-point claim `math.fixpoint.convergence-target@v1` |
| L6 `least_fixed_point_above` | if `step` is monotone, the limit from `x` is below every fixed point above `x` | same |
| L7 `refine_is_closure` | under L2's hypothesis `refine` is monotone, inflationary and idempotent | same |

L5 is where the code and the theorem part company; see finding F2.

CentiColons (`1550-jgve`):

| Id | Statement | Discharges |
|---|---|---|
| C1 `earned_le_denominator` | earned is at most the denominator | `earned_cc_is_bounded_between_zero_and_total_cc` |
| C2 `residual_identity` | residual plus earned equals the denominator, with no truncation | `residual_cc_equals_total_cc_minus_earned_cc` |
| C3 `earned_monotone`, `residual_antitone` | with weights, bars and tombstones fixed, `x <= y` implies earned does not fall and residual does not rise | the two `…_for_valid_fixed_denominator_transitions` checks |
| C4 `preservation_implies_nonincrease` and `nonincrease_not_preservation` | keeping every earned obligation earned implies the residual does not rise; the converse is false (one gain hides one loss), with the concrete witness | specifies the ratchet (per obligation, not the total) |
| C5 `reaches_zero` | if the residual never rises and, while positive, drops within every `K` cycles, it is zero by cycle `K * R0` | the conditional bound on the Level 5 page |
| C6 `tombstone_is_scope_change` | tombstoning a positively weighted obligation changes the denominator; residuals across it are not comparable, with a witness where the residual falls and no evidence changed | `denominator_changes_emit_scope_changed`, `tombstone_and_scope_change_transitions_are_explicitly_non_monotone` |
| C7 `residual_not_gameable`, `percent_gameable` | adding an already-earned obligation leaves the residual unchanged and strictly raises the percentage when the residual is positive | `anti_gaming.adding_trivial_requirements_must_not_inflate_project_score` in `methodology/proximity.yaml` — true of the residual, false of the percentage |

`same_frozen_state_same_router_same_weights_same_score` is not a theorem to
prove: in Lean the score is a function, so it holds by construction. What can
break it in production is a hidden input, and that is what the `Cacheable`
predicate class exists to exclude (§6.2).

Ledger fold (`1550-5i2w`):

| Id | Statement |
|---|---|
| S1 `wins_is_not_a_join` | the pairwise status decision is not commutative, with the witness |
| S2 `sorted_fold_is_a_function_of_the_set` | sorting by `(ts, filename)` then folding gives the same result for every arrival order of the same fragments |
| S3 `compaction_equivalence` | compacting any subset and then folding the rest equals folding everything at once — FALSE today (finding F1); to be proved after `1550-8528` is fixed |

### 4.3 Statement shapes (NOT COMPILED — no Lean exists on any host yet)

```lean
-- the seven evidence states, in order
inductive Ev | absent | declared | traced | posTested | negTested | runtimeObs | bundled

abbrev State (n : Nat) := Fin n → Ev          -- ordered componentwise

structure Rule (n : Nat) where
  id      : Fin n
  to      : Ev
  applies : State n → Prop

-- L1: one step never lowers anything, for ANY rule set
theorem step_inflationary (rs : List (Rule n)) (x : State n) : x ≤ step rs x

-- L2: upward-closed predicates make the step monotone
theorem step_monotone (rs : List (Rule n))
    (h : ∀ r ∈ rs, ∀ x y, x ≤ y → r.applies x → r.applies y) :
    Monotone (step rs)

-- C3: more evidence never raises the residual
theorem residual_antitone (w : Fin n → Nat) (bar : Fin n → Ev)
    {x y : State n} (h : x ≤ y) : residual w bar y ≤ residual w bar x

-- C5: no regression + a drop within every K cycles while positive
theorem reaches_zero (R : Nat → Nat) (K : Nat)
    (noRegress : ∀ k, R (k + 1) ≤ R k)
    (progress : ∀ k, 0 < R k → R (k + K) < R k) : R (K * R 0) = 0
```

The operator reviews statements like these, in this form, before proof work
starts (requirement in the OpenSpec change; task 2.1).

## 5. Findings

### F1 — a falsified descent forgets its falsification once compacted (MEASURED) — `1550-8528`

Measured on yoga, 2026-10-04, binary `tillandsias-plan build-id`
`0.1.0+579b43ef754b46de` (trunk 9dae9870b), on scratch ledgers selected with
the global `--index` flag. Base: one packet at `status: completed`. Fragment
A: `status = verified`, ts 2020-01-01, host h1. Fragment B: `status = ready`,
ts 2026-01-01, host h2, carrying a `falsified` event for the packet.

| Sequence | `tillandsias-plan --index … status subject` |
|---|---|
| control: base alone | `completed` |
| A and B both present, folded | `ready` |
| B alone, folded | `ready` |
| B compacted (`compact`: "compacted 1 fragment(s)"), then A arrives, folded | `verified` |

The same two fragments give `ready` or `verified` depending on whether the
falsified descent was compacted before the older, higher-rung fragment
arrived. The mechanism, read from `fold_with_sources` and `status_entry_wins`
in `fragments.rs`: a fragment's descent is honoured only when the same
fragment carries a `falsified` event (`fragment_falsifies`); once compacted,
the base row holds only `status: ready`, and the base arm compares an
incoming fragment against it with empty timestamps and no falsification, so
an incoming rung beats a working state unconditionally.

The compacted base still contains the falsified event with its timestamp
under the packet's `events` — the data to decide correctly is present and is
not consulted.

Why it matters: a host returning with an old `verified` or `completed`
fragment silently re-closes work that was explicitly falsified. Returning
hosts with stale fragments are the expected condition (context of archived
order 1123-k3mq).

How it differs from 1123-k3mq (completed, archived): that row made compaction
apply the same ladder as the runtime fold, and its negative control — an
older `verified` still beats a newer `completed` when NO falsification is
involved — is pinned by
`compaction_keeps_the_ladder_teeth_an_older_higher_rung_still_wins`. That
control must keep passing. This finding is the case with a falsification,
across a compaction boundary, which no test in `fragments.rs` names.

Related open row 1073-xays (same root, different defect): compaction discards
the winning status entry's host and ts because the base schema has nowhere to
put them, which leaves old claims unattributable. Its shape (a)
(`status_host` / `status_ts` on the base row) would also supply the clock
that repair (b) below needs. The fragment that files `1550-8528` carries a
note event on 1073-xays saying so.

Candidate repairs, for whoever takes the row (the choice is theirs to argue):
(a) the base arm consults the packet's own compacted `falsified` events and
refuses an incoming non-falsified rung whose `ts` is not later than the
latest falsification; (b) compaction writes the falsification clock beside
the status; (c) rule that an unseen older rung is new evidence and change the
uncompacted fold to agree. (a) needs no new field.

### F2 — `Refiner::refine` refuses valid long chains (MEASURED) — `1550-a5jc`

Measured on yoga, 2026-10-04, with a temporary test appended to
`obligation_props.rs` (file restored afterwards): a chain of `n` rules, rule
0 unconditional and rule `i` raising obligation `i` to `Declared` when
obligation `i-1` is at least `Declared`. Every predicate is upward closed, so
the rule set satisfies the hypotheses of L2 and L5.

| n | outcome | obligations declared |
|---|---|---|
| 10 | `Fixed steps=10` | 10/10 |
| 63 | `Fixed steps=63` | 63/63 |
| 64 | `Unstable bound=64` | 64/64 |
| 65 | `Unstable bound=64` | 64/65 |
| 70 | `Unstable bound=64` | 64/70 |

`refine` hard-codes `const BOUND: usize = 64`. The theorem's bound is the
lattice height (`6n`) or the rule count, plus one iteration to observe that
nothing changed. At `n = 64` the state IS the fixed point and is reported as
not one. The failure is closed (it never reports a false fixed point), so the
severity is low; the defect is that the code's bound is a constant where the
proof's bound is a function of the input.

### F3 — unchecked `u64` sums in the scorer (BY SOURCE READING, not run)

`centicolon_function` accumulates `denominator += weight` and
`earned += weight` on `u64`, and `[profile.release]` in the workspace
`Cargo.toml` sets no `overflow-checks`, so a release build wraps on overflow.
Real weights are two- and three-digit numbers, so this is unreachable in
practice; it is recorded because it is the first thing a Kani harness over
arbitrary weights will report, and the repair (checked addition, or a stated
bound on weights) is part of `1550-5sek`.

### F4 — the refinement operator has no production caller (MEASURED by search)

`grep -rn -E 'Refiner::new|\.refine\(|monotone_rules\(\)' crates
--include='*.rs'` excluding `obligation.rs` and `obligation_props.rs`
returned 0 lines on trunk 9dae9870b. `Refiner` is exercised only by its own
unit tests and by the three-rule fixture `monotone_rules`. So the convergence
theorem is about an operator that no production path runs: what raises
obligation states in production is `tillandsias-plan score-checks` (a passing
CI check establishes `PositivelyTested`) and the Lua graders
(`scripts/lua/centicolon-extract.lua`, `centicolon-grade-static.lua`,
`centicolon-grade-observed.lua`). Naming that live operator rule by rule is
`1550-sy27`; the Level 5 RED "they exercise a committed rule set rather than
every live validator" (`level-5-phd.md:92`) is this finding.

## 6. Wiring

### 6.1 Methodology

`claim_strength` in `methodology/provenance.yaml` has four values; the
strongest, `project_invariant`, means "validated by Tillandsias litmus tests,
CI checks, and repository history". A machine-checked theorem about a model
is a different kind of evidence and needs its own value with a mandatory
limit: proved of the model, silent about code and world. Each check in
`validation_program` phases 1 and 2 gains the name of the theorem that proves
it; phase 3 (empirical calibration) is untouched. Naming the value and its
wording is decision D1; the edit is `1550-jsvt`.

### 6.2 Pure predicates

`PredicateClass` in `lua_predicate.rs` has two values: `Cacheable` (verbs
`log_info`, `verbs`; no shell, no clock; results may be cached) and
`Observing` (adds `now_ms`, `shell`; never cached). Three connections:

1. Determinism. A `Cacheable` predicate is a function of repository bytes.
   That is the hypothesis every theorem about a closure predicate needs, and
   it is enforced by construction of the environment rather than by review.
   `Observing` predicates are outside every theorem.
2. Per-rule monotonicity. L2 and L7 reduce "the live operator converges" to a
   local property of each rule predicate: upward closure. A pure predicate can
   be checked for it exhaustively over a small domain (`1550-sy27`).
3. One scoring definition. Today there are three: the Lua graders (a count at
   the positive-test bar, `ok:centicolon-grade:R=… satisfied=… denominator=…`),
   the Rust scorer (weights over CI check names), and the full policy in
   `methodology/proximity.yaml` (multipliers, credits, six caps, sixteen
   penalties). The Lean model is executable and emits expected values that
   both implementations are tested against (`1550-88nf`). Today's cacheable
   predicates take repository bytes, not abstract evidence states, so the
   conformance point is the arithmetic over the per-obligation rung list, not
   the extraction.

Verifying Lua source directly in Lean is not proposed; no practical toolchain
exists for it.

### 6.3 Gate placement

Not in `./build.sh --check`. The lane is its own entry point with one verdict
line, run on Linux builders. A host without the formal image reports a named
skip, never `ok`. Committed vectors let macOS and Windows hosts run the
conformance tests without Lean; a Linux check regenerates them and refuses a
difference. Cadence is decision D4.

The methodology's own complexity constraint (`ratio_constraint` and its "Red
flag: CI validators exceed 5000 lines or require specialized training to
understand", `methodology/convergence.yaml`) applies: Lean is specialised
training. The lane stays small (a few hundred lines of Lean, one script, one
registry) and replaces prose proofs rather than adding a second copy.

## 7. Builder placement and the runtime boundary (ruling R1)

- Lean and Kani run only on builders: in a pinned OCI image started by
  podman, reached through the existing toolbox-first pattern
  (`multi_host_development.toolbox_first_scripts` in
  `methodology/multi-host-development.yaml`).
- The builder toolbox's init set (`_toolbox_initialized` in
  `scripts/with-tillandsias-builder.sh`) is paid by every host on every
  bootstrap. A multi-gigabyte proof toolchain does not belong in it; a
  separate image pulled on first use of the lane does.
- No Lean or Kani artifact is linked into, bundled with, or downloaded by
  any shipped binary or image. Lean proofs produce no runtime artifact; Kani
  harnesses compile out. A check asserts this rather than leaving it to
  review.

## 8. Website (`../tillandsias.org`) — after a stable release, not before

The site footnotes the pinned STABLE release
(`skills/update-website/SKILL.md` there). Nothing changes on the site until
a stable release carries the lane. Then, in `docs/matrix/level-5-phd.md`
(line numbers at site commit f6d57f5):

- Proposition 1, Theorem 3 and the conditional cycle bound cite checked
  theorem names instead of carrying prose proofs.
- The RED at line 92 narrows to: proved for the model for every rule set with
  upward-closed predicates; what remains is the per-rule check of the live
  operator.
- The REDs at lines 155 and 362 narrow only if the single scoring definition
  and its vectors have landed.
- A legend separates four words: proved (model), model-checked (code,
  bounded), tested, empirical.
- Unchanged: the progress premise, the zero floor, the absent Galois
  connection, the withdrawn strong-law citation. Finding 1b27ef15 stands;
  nothing here restores a retracted claim.

The site work is `1550-gtcx` and follows that repository's own process (an
OpenSpec change there, appended ledger events, never rewritten fragments).

## 9. Not proposed

- Lean or Kani in the user runtime.
- A per-release "proof certificate". Comparing two finite states is a
  computation; a prover adds nothing to it.
- A Galois connection, a contraction metric or a probability layer. The
  methodology names these as absent, and nothing here builds them.
- A convergence theorem for dependent agent iterations. It needs a stochastic
  model nobody has.
- TLA+ for the claim and lease protocol. Plausible later; not scoped.
- Translating Rust to Lean (Aeneas) or verifying Lua in Lean.

## 10. Open decisions for the operator (`1550-c4ht`)

| | Decision | Recommendation |
|---|---|---|
| D1 | Name and wording of the new claim strength | `machine_checked_model`, with the limit sentence in §6.1 |
| D2 | Depend on Mathlib, or core Lean only | Mathlib, in the pinned image; decide after `1550-n4eb` measures its size |
| D3 | Adopt Kani | Yes, Linux x86_64 builders only, behind the same lane |
| D4 | Cadence of the lane | On changes to the model, the scorer or the vectors, and before a release; not on every push |
| D5 | Who reviews theorem statements | The operator, once, at task 2.1; later changes to a registered statement need the same review |

## 11. Packets

| Order | Kind | What |
|---|---|---|
| 1550-32d6 | milestone | the lane as a whole |
| 1550-c4ht | research | decision record D1–D5 |
| 1550-8528 | bug | F1, the compacted falsification |
| 1550-a5jc | bug | F2, the refiner bound |
| 1550-n4eb | feature | the builder-only lane, image and registry |
| 1550-7qz6 | feature | Lean: lattice and refinement (L1–L7) |
| 1550-jgve | feature | Lean: CentiColon ranking (C1–C7) |
| 1550-5i2w | feature | Lean: the status-ladder fold (S1–S3) |
| 1550-88nf | feature | vectors and three-way conformance |
| 1550-sy27 | research | the live refinement operator, rule by rule (F4) |
| 1550-5sek | feature | Kani on the Rust scorer (F3) |
| 1550-jsvt | feature | methodology wiring and the cheatsheet |
| 1550-gtcx | feature | the website, after a stable release |
| 1550-xath | research | goal: Kani on the wire-framing decoders |

## 12. Sources

- `methodology/math-foundations.yaml`, `methodology/proximity.yaml`,
  `methodology/philosophy.yaml`, `methodology/provenance.yaml`,
  `methodology/convergence.yaml`, `methodology/multi-host-development.yaml`,
  `methodology.yaml` — read on trunk 9dae9870b.
- `crates/tillandsias-plan/src/obligation.rs`, `obligation_props.rs`,
  `fragments.rs`, `lua_predicate.rs`; `scripts/lua/centicolon-*.lua`,
  `scripts/centicolon-grade.sh`, `scripts/with-tillandsias-builder.sh`.
- `../tillandsias.org/docs/matrix/level-5-phd.md`,
  `../tillandsias.org/docs/audit/2026-09-28-centicolon-guarantee-addendum.md`,
  `../tillandsias.org/issues.d/20260928T170748Z-centicolon-guarantee-retraction-codex-macuahuitl.yaml`
  — site commit f6d57f5.
- https://lean-lang.org/install/manual/ and
  https://model-checking.github.io/kani/install-guide.html — fetched
  2026-10-04. Everything else said about Lean, Mathlib and Kani in §3 is from
  the author's prior knowledge and is to be re-verified against those tools'
  documentation by `1550-n4eb` and `1550-5sek` before it is relied on.
- Tarski 1955, Davey and Priestley 2002, Floyd 1967 — as catalogued in
  `reference_catalog` of `methodology/math-foundations.yaml`.
