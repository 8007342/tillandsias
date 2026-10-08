# Tasks — formal-verification-lane

Packet orders in brackets; dependency order top to bottom. Each task's
closure is the test or script named in its packet's `verifiable_closure`,
or the stated reason in its `unscoreable`. Design note:
`plan/issues/formal-verification-lane-design-2026-10-04.md`.

## 0. Needs no new tooling and nothing from the operator

- [ ] 0.1 Status fold: compaction equivalence under falsification, failing test first [1550-8528, opus]
- [ ] 0.2 Refiner iteration bound derived from the rule set [1550-a5jc, sonnet]
- [ ] 0.3 Name the live refinement operator rule by rule; classify each predicate [1550-sy27, opus]

## 1. Decisions

- [ ] 1.1 Decision record D1–D5 drafted and signed by the operator [1550-c4ht, opus]

## 2. The lane

- [ ] 2.1 Image definition, Lean project skeleton, theorem registry, entry point with ok / refused / skipped [1550-n4eb, opus]
- [ ] 2.2 Fixture: the `sorry` arm, the user-axiom arm and the missing-theorem arm each go red [1550-n4eb]
- [ ] 2.3 Measure image size with and without Mathlib, and cold / warm wall time on yoga (feeds D2) [1550-n4eb]
- [ ] 2.4 Check that no shipped artifact references Lean or Kani [1550-n4eb]

## 3. Theorems (statements reviewed by the operator before proofs)

- [ ] 3.1 Lattice and refinement, L1–L7 [1550-7qz6, opus]
- [ ] 3.2 CentiColon ranking, C1–C7 [1550-jgve, opus]
- [ ] 3.3 Status-ladder fold, S1–S3 (S3 after 0.1) [1550-5i2w, opus]

## 4. Model to code

- [ ] 4.1 Vectors emitted by the Lean model; Rust test and pure Lua scoring predicate consume them; Linux staleness check [1550-88nf, opus]
- [ ] 4.2 Kani harnesses on the factored score arithmetic; checked sums — only after D3 [1550-5sek, opus]

## 5. Methodology and specs

- [ ] 5.1 New claim strength with its limit; theorem ids on `validation_program`; anti-gaming wording; cheatsheet [1550-jsvt, opus]
- [ ] 5.2 Sync `formal-model-verification` and the `methodology-accountability` addition into `openspec/specs/` with requirement identifiers [1550-jsvt]

## 6. Website (sibling repository, after a stable release carries the lane)

- [ ] 6.1 Level 5 cites theorem names; four-word legend; nothing retracted is restored [1550-gtcx, opus]

Not in scope (goal): Kani on the wire-framing decoders [1550-xath].
