# Design — formal-verification-lane

Sources for every fact, measurement and operator quotation:
`plan/issues/formal-verification-lane-design-2026-10-04.md` (§ numbers below
refer to it). This file states the decisions that follow.

## Layers

```
WORLD   the progress premise, adequacy of the obligation set,
        whether a test tests what it claims          empirical; no tool here
------------------------------------------------------------------------------
CODE    Rust scorer and fold, Lua graders            tested against vectors
                                                     (and bounded-checked by
                                                     Kani, pending D3)
------------------------------------------------------------------------------
MODEL   lattice, refinement, ranking function, fold  proved in Lean
```

Every claim names its layer. The four words: PROVED (of the model),
MODEL-CHECKED (of the code, up to a stated bound), TESTED, EMPIRICAL.

## Decision 1 — Builder-only, in a separate pinned image

Ruling R1. Lean (and Kani, if adopted) run inside a pinned OCI image
started by podman on Linux builders, reached through the existing
toolbox-first pattern. The image is NOT part of the builder toolbox's init
set (`_toolbox_initialized` in `scripts/with-tillandsias-builder.sh`), which
every host pays on every bootstrap; it is pulled on first use of the lane.
The image is pinned by digest and the Lean toolchain by a `lean-toolchain`
file. No shipped binary, image or installer references either tool, and a
check asserts that.

## Decision 2 — The verdict comes from axioms, not from the build

A Lean proof containing `sorry` compiles with a warning and depends on the
axiom `sorryAx`; a user-declared `axiom` proves anything; `native_decide`
trusts the compiler rather than the kernel. The lane therefore reads, for
each REGISTERED theorem, the axioms it depends on, and passes only when all
of them are in an allowlist (`propext`, `Classical.choice`, `Quot.sound`).
A registry entry whose theorem does not exist is a refusal. The fixture for
the lane proves each of these arms can go red before any real theorem is
written.

## Decision 3 — A registry ties theorems to methodology claims

One file lists each theorem by name with the methodology check it
discharges (`validation_program` in `methodology/math-foundations.yaml`)
and the layer word. The lane reads it; the methodology cites theorem ids
from it; the website footnotes it. A claim may carry the machine-checked
strength only while its theorem is in the registry and the lane is green —
checked, not asserted.

## Decision 4 — Statements are reviewed before proofs are written

A vacuous or mis-modelled theorem is green and worthless, and a kernel
cannot see that. The operator reads the statements (a page of them, in the
form shown in §4.3) before proof work starts; changing a registered
statement needs the same review. Proofs need no human review.

## Decision 5 — The model mirrors the code where it matters

- Seven evidence states in the order of `ObligationState`.
- One step applies every rule against the OLD state and raises the target
  to `max(current, to)`, as `Refiner::step` does.
- A tombstoned obligation leaves numerator and denominator and marks the
  score as outside the monotone regime, as `centicolon_function` does.
- The negative control is the same wrong model the Rust tests commit
  (`non_monotone_rules`).

The model is the BINARY contract (earned at a bar). The full weighted policy
of `methodology/proximity.yaml` is not modelled by this change; whether it
is monotone is recorded as open.

## Decision 6 — Vectors are the only model-to-code link, and they are tests

The Lean model emits a committed vector file over an enumerated domain that
the file itself states. One Rust test and one test of a pure (`Cacheable`)
Lua scoring predicate consume it. A host without Lean runs both from the
committed file; a Linux check regenerates the file and refuses a
difference, so the committed artifact cannot go stale silently. The vectors
are emitted by Lean itself — no Python, no new jq call sites.

Today's Lua graders take repository bytes and a results log. The
conformance point is the arithmetic over the per-obligation rung list; if
that is not already a function of the list, factoring it is the first step
of `1550-88nf`.

## Decision 7 — Not in the gate; a named skip where absent

The lane is its own entry point with one verdict line. It does not run in
`./build.sh --check`. Three outcomes with three distinct exit statuses:
ok (naming the theorem count), refused (naming the theorem and the reason),
skipped (naming the missing image). Skipped is never reported as ok. One
gate per host still holds: the lane does not run concurrently with a gate.
Cadence is decision D4.

## Decision 8 — The two bugs do not wait for the lane

`1550-8528` and `1550-a5jc` were measured with the existing binary and a
temporary test. They are ordinary Rust fixes with ordinary tests and land
first. `1550-5i2w` proves compaction equivalence only after `1550-8528`
makes it true.

## Decision 9 — Kani is pending, and bounded

Adopting Kani is the operator's decision D3. If adopted: x86_64 Linux
builders only (the install page lists no aarch64 Linux or Windows host),
harnesses behind `cfg(kani)` in new modules, the scorer's arithmetic
factored out of the string-keyed map first, and every result cited with the
bound it holds for.

## Decision 10 — Complexity is a cost the methodology already names

`methodology/convergence.yaml` flags validators that "require specialized
training to understand". The lane stays small — a few hundred lines of
Lean, one entry script, one registry — and replaces the website's prose
proofs rather than adding a second copy of them.

## Open decisions (operator, `1550-c4ht`)

D1 claim-strength name and wording; D2 Mathlib or core Lean; D3 Kani;
D4 cadence; D5 statement review. Recommendations and the facts each waits
for are in §10.

## What this change does not claim

It does not prove the project converges. It does not prove the code
correct. It does not establish the progress premise, a zero residual floor,
a contraction, a Galois connection or any probability. It makes the model's
own theorems checked, gives the implementations one definition to answer
to, and says which is which.
