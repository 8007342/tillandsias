# CODE EXPERT: per-file version trajectory, semantic distillation, and convergence-awareness as a fine-grained authority layer

- Date: 2026-07-17
- Source: operator (The Tlatoāni) session directive, distilled by
  windows-bullo-fable5-20260717 (host session)
- Milestone: forge-local-experts-milestone (order 391) — this is the CODE
  EXPERT's charter, the third expert after PLAN + METHODOLOGY
- Related: order 398 (compiled deterministic plan-ledger engine),
  order 329 (forge hot-path placement/RAM-disk), methodology
  `monotonic_reduction_of_uncertainty_through_verifiable_constraints`,
  `plan/issues/agent-fleet-and-zeroclaw-roadmap-2026-07-17.md` (zeroclaw is
  the experts' main consumer, gated on their reliability).

## The problem the CODE EXPERT solves

Agents today query git for the latest commit and often just browse the
filesystem to understand code. That is slow (cold path, file walking) and
blind to history: an agent cannot see that a file has been rewritten back
and forth, that a sibling module already hit the same wall, or that the
codebase converged on a common library for stability. So agents re-tread
dead ends and re-introduce instability that a reviewer with memory would
catch instantly.

## What the CODE EXPERT knows (built at forge launch, refreshed on commit/push)

For EACH file, the ephemeral local model is built with:

1. **Latest version** — the current content/shape (symbols, methods,
   public surface), authoritative for "what exists now".
2. **Version trajectory** — the last few versions of the file, so the
   expert can see how it got here (what was tried, reverted, reshaped).
3. **Semantic-distillation summary of the longer trail** — a compressed
   narrative of the file's deeper history (not raw diffs): the arc of how
   the implementation converged, which approaches were abandoned and why,
   what invariants hardened over time. This is the same distillation
   discipline the methodology applies to prose (root files stay terse;
   rationale distills to the owning component), now applied to code
   history.

Everything ephemeral (milestone 391 invariant): built from the freshly
mounted checkout at launch, refreshed on commit/push so answers track the
tree, gone on shutdown.

## What the CODE EXPERT does with it

- **Answers "how do I add a method that does Foo?"** with lived context,
  e.g.: *"try Baz and Bar, but previous agents tried X and reverted it;
  sibling code Y had issues with Z, so we standardized on the common
  library W for stability."* Not just "here's the API" — the accumulated
  judgment of every agent that touched this layer.
- **Flags unnecessary instability in code review**: a file (or method)
  being flipped back and forth between shapes across recent versions is
  surfaced as churn/instability, not progress. Work that oscillates does
  not reduce uncertainty — the expert names it.
- **Notes implementation convergence**: per methodology's monotonic
  reduction of uncertainty through verifiable constraints, the expert
  reports whether a file/area is CONVERGING (each version hardened an
  invariant, added a pin, narrowed ambiguity) or DIVERGING (re-litigating
  settled decisions, widening surface without verification). Convergence
  is a first-class signal the expert emits.

## Experts as fine-grained layers of authority

Each expert is the authority for the layer it represents:

- PLAN EXPERT — authority on the ledger/graph (blocked-by, residuals).
- METHODOLOGY EXPERT — authority on discipline/process.
- CODE EXPERT — authority on the code's current shape AND its trajectory
  and convergence.

Models and methodology work TOGETHER: the methodology defines the
verifiable constraints; the experts are the fast, local, always-current
oracles that tell an agent where each layer stands against those
constraints. Collectively they drive the project's monotonic reduction of
uncertainty — every query answered from a converged local view instead of
a cold filesystem walk.

## Velocity thesis (why this is the hot path)

- Optimize the hot path at EVERY step: the files agents read live in the
  RAM-disk hot path (order 329); the experts are simplified local
  inference over that same hot data → super fast, super cheap.
- Break long-running tasks into short, high-confidence, verifiable steps:
  each step reduces uncertainty against a constraint; the CODE EXPERT's
  convergence signal tells you whether a step actually hardened the tree
  or just moved it sideways.
- Entirely local, fully open-source stack: no external calls on the hot
  path; the expert answers from the freshly built local model.

## Shaping into the milestone (verifiable rungs)

Filed as a child of order 391 (see plan/index.yaml
code-expert-file-trajectory-convergence). Smallest verifiable slices,
each a ground-truth-graded closure per 393's harness:

1. **Build inputs**: per-file (latest shape + last-N versions + distilled
   trail) extracted from the mounted checkout's git history at launch;
   pinned by a fixture asserting the trail for a known file.
2. **Convergence/instability signal**: a deterministic metric over the
   trajectory (e.g. revert/oscillation detection, invariant-add vs
   invariant-remove) the expert can cite — verifiable on a seeded
   flip-flop fixture (the metric MUST flag a back-and-forth series and
   NOT flag a monotonic hardening series).
3. **Expert answers**: the ephemeral model answers a "how do I add Foo"
   query with the trajectory-aware context on the ground-truth set;
   refreshed on commit and re-graded.
4. **Authority-layer integration**: the code-review path consults the
   CODE EXPERT for instability/convergence flags (feeds /code-review).

Deferred until 391's PLAN+METHODOLOGY experts prove the ephemeral
build/refresh/tier machinery (392/393/401/402) — the CODE EXPERT reuses
that substrate; only the per-file trajectory+distillation inputs and the
convergence metric are new.
