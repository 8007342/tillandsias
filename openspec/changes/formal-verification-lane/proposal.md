# Proposal — formal-verification-lane

Umbrella packet: `1550-32d6` (milestone, desired_release v0.7). Research,
measurements and the operator's rulings (quoted verbatim):
`plan/issues/formal-verification-lane-design-2026-10-04.md` — § numbers
below refer to it.

## Why

The methodology's core principle is monotonic reduction of uncertainty under
verifiable constraints, and `methodology/math-foundations.yaml` states the
mathematics it is willing to defend: a finite obligation lattice, refinement
to a fixed point, CentiColons as a bounded ranking function, and explicit
non-claims (no contraction, no Galois connection, no probability). Today
those theorems exist as prose proofs on the website's Level 5 page and as
sampled property tests over a three-rule fixture. Nothing checks the proofs,
and three scoring definitions (the Lua graders, the Rust scorer, the full
policy in `methodology/proximity.yaml`) disagree with nothing comparing them.

Operator direction (2026-10-04, §1): use a proof language where it helps,
on builder infrastructure only — toolboxes and podman containers,
transparent on Linux hosts, nothing in the user runtime without a stated
justification — wire it into the methodology and the pure Lua predicates,
and update the website to match.

Facts that decide the shape:

1. A proof assistant (Lean 4) proves statements about a MODEL for every
   state and every rule set. It says nothing about whether the Rust or Lua
   implements that model, and nothing about the progress premise, which is
   an empirical hypothesis about the project (§2).
2. In Lean a proof containing `sorry` compiles. A lane that reads only the
   build's exit status is green for an unproved theorem (§3.1).
3. Stating the properties precisely already found two defects, both
   measured on trunk 9dae9870b without any prover (§5): a falsified status
   descent is reverted by an older higher-rung fragment once it has been
   compacted (`1550-8528`), and `Refiner::refine` reports a valid chain of
   64 or more rules as unstable (`1550-a5jc`).
4. `Refiner` has no production caller (§5 F4). The finite-stabilisation
   theorem is about an operator that only a fixture exercises; the live
   operator has to be written down before any theorem applies to it.
5. The `Cacheable` predicate class (no shell, no clock) is what makes a Lua
   predicate a function of repository bytes — the hypothesis a theorem about
   a closure predicate needs (§6.2).

## What Changes

- **ADDED** capability `formal-model-verification`: a builder-only lane
  that checks registered Lean theorems in a pinned image, decides by the
  axioms each theorem depends on rather than by the build's exit status,
  reports a named skip where the toolchain is absent, never runs in
  `./build.sh --check`, and never ships in the user runtime; a theorem
  registry tying each theorem to the methodology check it discharges;
  operator review of statements before proofs; expected-value vectors
  emitted by the proved model and consumed by the Rust scorer and a pure
  Lua scoring predicate; an optional bounded model checker (Kani) for the
  Rust arithmetic, pending decision D3.
- **ADDED** to `methodology-accountability`: a claim that a property is
  machine-checked carries its own claim strength with a mandatory limit
  (proved of the model; silent about code and world), may be cited only
  while its theorem is registered and green, and never upgrades a
  conditional or withdrawn claim.
- **Fixed** (bugs, independent of the lane): `1550-8528` (compaction
  equivalence of the status fold under falsification), `1550-a5jc` (the
  refiner's iteration bound).
- **Research**: `1550-sy27` names the live refinement operator rule by rule
  and classifies each predicate; `1550-c4ht` is the operator's decision
  record for D1–D5 (§10).
- **Website**: `1550-gtcx`, in the sibling repository, only after a stable
  release carries the lane.
- **Goal filed, not in scope**: Kani on the wire-framing decoders
  (`1550-xath`).

Nothing about what the methodology declines to claim changes. The progress
premise stays empirical, the zero floor stays unproved, and no retracted
claim is restored.

## Impact

- Specs: one new capability and one added requirement (deltas under
  `specs/`), synced into `openspec/specs/` by `1550-jsvt` with requirement
  identifiers.
- Code (by packet): a Lean project under `formal/` and an image definition
  under `images/formal/` (`1550-n4eb`); Lean sources for the lattice, the
  ranking function and the fold (`1550-7qz6`, `1550-jgve`, `1550-5i2w`);
  committed vectors under `formal/vectors/`, a Rust test module and a pure
  Lua scoring predicate (`1550-88nf`); new Rust modules for factored score
  arithmetic and its harnesses (`1550-5sek`); `fragments.rs` and
  `obligation.rs` for the two bugs.
- Methodology: `methodology/provenance.yaml`,
  `methodology/math-foundations.yaml`, `methodology/proximity.yaml`, one
  cheatsheet (`1550-jsvt`), after decision D1.
- Builder hosts: one additional image, pulled on first use of the lane.
  The builder toolbox's init set is unchanged.
- User runtime: nothing. A check asserts it.
- Out of scope: Lean or Kani in any shipped artifact; a Galois connection,
  a contraction metric or a probability layer; a convergence theorem for
  dependent agent iterations; per-release proof certificates; verifying Lua
  or translating Rust into Lean; TLA+ for the claim protocol.
