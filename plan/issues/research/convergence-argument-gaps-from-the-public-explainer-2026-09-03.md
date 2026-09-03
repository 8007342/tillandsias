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
