# Three gaps under the convergence argument — CAPTURED, NOT PROMOTED

**Status: operator decision required. This is deliberately NOT a plan packet.**

Found by `macuahuitl-tillandsias.org-forge` while writing the public explainer
at tillandsias.org, and surfaced by the coordinator rather than filed as rows.
Promotion is Tlatoāni-gated (2026-08-19), and each of these reframes a
project-level argument rather than reporting a bug — which is exactly the class
the gate exists for. Capture is mandatory; a new row is not.

All three are **documentation defects, not design defects**. Nothing about the
iteration scheme has to change for any of them.

## 1. The stated validation programme is unexecuted

`methodology/math-foundations.yaml` sets out its own validation programme,
which calls for property-testing monotone transitions and score monotonicity.
**No `proptest` or `quickcheck` dependency exists in any manifest in the tree.**
Phases 1 and 2 of the programme are therefore unrun — not failing, unrun.

## 2. The lattice model's stable IDs do not exist as data

The model assumes obligations carry stable identifiers, and componentwise
comparison across releases is defined in terms of aligning them. **No spec file
carries a requirement identifier field**; `requirement_has_stable_id` occurs
exactly once in the whole tree. The comparison is defined over a key that is
not present in the artifacts being compared.

## 3. The strong law is invoked outside its hypotheses

This is the sharpest of the three and the cheapest to repair.

`philosophy.yaml` applies the strong law of large numbers to a sequence the
design **deliberately makes dependent**: the RAG cache converges knowledge onto
commits, so iteration *k+1* reads iteration *k*'s output. Independence is a
hypothesis of the theorem, not a stylistic assumption, so the invocation is
unearned as written.

**The repair does not touch the design — it changes the citation.** Name the
dependence structure the cache-on-commits design creates, then invoke a theorem
that tolerates it:

- **Birkhoff's ergodic theorem** — needs stationarity and ergodicity argued.
- **A martingale convergence law** — needs `E[X_{k+1} | F_k] = mu` argued.

Neither is currently argued. The reporter's own framing: this is the sort of
thing a referee finds in the first ten minutes.

## Why this matters more than usual

**These findings are already public.** The explainer states the project's
shortcomings alongside its strengths, with every claim footnoted to a blob link
pinned at `v56.9.2.1`, at operator direction. So the choice is not whether to
disclose but whether the public text cites a theorem that covers its own
sequence.

## For the operator

Three separable decisions:

1. Add a property-testing dependency and execute phases 1 and 2, or amend
   `math-foundations.yaml` to describe a programme that matches what is run.
2. Introduce a requirement-identifier field, or restate the lattice comparison
   over a key that exists.
3. Amend the `philosophy.yaml` citation to a theorem whose hypotheses the
   design satisfies. Cheapest of the three; largest credibility effect.

The explainer's author has offered to re-pin the page to a newer tag as fixes
land, so a line range drifting under it is not a blocker.

---

# ADDENDUM 2026-09-03T02:35Z — implementation shape, and an approval NOT acted on

The explainer's author returned with the work decomposed and reports that **the
operator approved all three** and ruled that the author does not touch the
Tillandsias tree, handing implementation here.

**I have not filed packets on that.** A relayed approval is not the operator
speaking, and these three were gated to them precisely because they reframe a
project-level argument. The gate is cheap to satisfy and expensive to bypass,
so it stays shut until the operator says so directly. Everything below is
capture, verified here rather than taken on report.

## Verified against the tree

| Claim | Result |
|---|---|
| `ObligationState` / `centicolon_function` in code | **0 occurrences** across `crates/` and `scripts/` |
| `evidence_bundled` (a distinctive lattice state) | **0 occurrences** |
| Spec files carrying a stable identifier | **0 of 177** |
| `requirement_has_stable_id` | a scoring weight of **0.10** at `methodology/proximity.yaml:53`, computed by nothing |
| The strong-law invocation | present verbatim: "the STRONG LLN (almost-sure convergence) makes the stream of iterations converge hard" |

**RETRACTED — see "CORRECTION" at the end of this file.** I claimed the
identifier occurs in **two** files rather than one. It does not: at the tag the
explainer pins there is exactly ONE, and my second hit was this very file
quoting the identifier it is about. The explainer is correct as published.

## 1. Strong law — a documentation edit

`methodology/philosophy.yaml`, `convergence_via_velocity.weak_vs_strong`
(L16-26). Four lines below, `rag_as_cache_commits_as_lamport_clock` (L31-38)
states the cache refreshes on commits, so iteration *k+1* reads iteration *k*'s
output. **The file constructs the dependence and invokes a theorem forbidding
it, in the same block.** Drop the almost-sure claim; keep the design intent and
the empirical evidence; state what a rigorous claim would require.

## 2. proptest — the prerequisite the author initially got wrong, and says so

Adding the dependency is small only *after* something that does not exist. The
model is paper: no enum, no transition table, no product state, no score
function. **There is nothing for a property test to exercise.**

Worse, what *is* computed is a different object wearing the same name:
`scripts/local-ci.sh` sums weights over passing CI checks (`total_cc`, L500 and
L521). That is a weighted checklist of gate results, not a ranking function over
a product lattice.

Order: implement the model; then the properties become trivial and meaningful;
then **rule on whether the shell scorer is meant to BE the scoring function.**
That last is an operator call — if yes it must call the model, if no then
`math-foundations.yaml` must stop implying the score it describes is the score
that ships.

Venue: proptest, not quickcheck, for integrated shrinking plus a committed
failing-seed corpus. The Lua layer was considered and rejected — it is swappable
decision policy with no reach into the Rust structures the properties concern.

## 3. Stable IDs — random identifiers, and the constraints that decide it

Ordered by how badly each bites if missed:

1. **The generator must be idempotent.** Stamp only what is missing, never
   reassign. A re-run that shuffles identifiers rebuilds the problem in a new shape.
2. **Never derive the identifier from path or heading text.** Surviving a file
   move is the entire point.
3. A validator enforces presence and uniqueness and fails on duplicates.
4. **Tombstones need identifiers too**, or retired requirements drop out of
   comparison and the non-regression check silently narrows its own denominator.
5. **The real design question, which is not the script:** when a requirement's
   text changes, does it keep its identifier (same obligation, better evidence)
   or get a new one plus a tombstone (different obligation)? Cross-release
   alignment means nothing until that is decided.
6. Keep the 0.10 weight unpaid until the validator enforces, or you credit a
   field no artifact is guaranteed to have.

## What is needed from the operator

One sentence confirming the approval directly, plus a ruling on 2(c) — whether
the shell scorer is meant to be the scoring function. With those, this becomes
three packets and I will assign them.

## CORRECTION — my "two files" count was my own echo

**Retracting the refinement above.** I claimed `requirement_has_stable_id`
occurs in two files rather than the one the explainer states. It does not, and
the explainer is right at the tag it pins.

The author could not reproduce my count and proposed the check that settles it:
grep a **committed ref**, not the working tree.

```
git grep -l requirement_has_stable_id v56.9.2.1        -> 1   (methodology/proximity.yaml:53)
git grep -l requirement_has_stable_id origin/linux-next -> 2
```

The second hit on trunk is **this file**. My capture note quotes the identifier
because it is a write-up *about* the identifier, and I ran a working-tree grep
after writing it. The instrument counted its own output as evidence.

**This is the night's dominant failure class and it is mine, again:** a
measurement that is real, reproducible, and answering a question adjacent to
the one asked. The specific trap is worse than an ordinary miscount, because
the extra hit reads as *corroboration* rather than as an echo — finding your
own claim restated looks like independent support for it.

The author's framing is the durable one and it generalises past this file: when
grepping for a term you have just written about, grep a committed ref that
predates your writing. The working tree contains your own artifact.

Earlier today I corrected this same author on a claim that a variable appeared
nowhere in the crates when it appeared in six files, and I was right then. This
one runs the other way. Both errors surfaced within an hour of being made, and
only because both parties re-checked instead of relaying.
