# The FRESHNESS audit class could not reach an unaudited file (order 640-iujb)

- Date: 2026-08-09
- Host: windows (windows-next), meta-orchestration cycle 3
- Class: `optimization/` — a standing per-cycle obligation that could not converge
- Status: fixed in this commit, pinned by a new anti-starvation litmus step

## The measurement that gives it away

Two audits of `scripts/freshness-inventory.sh`, nine days apart:

```
2026-07-31 (forge-antigravity):   969 components,  8 stamped,  0% coverage
2026-08-09 (this cycle):         1021 components,  8 stamped,  0% coverage
```

Nine days. **+52 components, +0 stamps.** The 07-31 audit's own stamp says
"same findings as prior audit — no new drift detected in the stamped set",
which is true, correct, and completely beside the point: the stamped set was
eight files and never grew.

## Why it could not move

`methodology.yaml` → `component_freshness` makes each cycle re-validate "the top
component the `freshness-advisory` phase flagged". That phase ranks
`freshness-stale:` lines by age (`local-ci.sh`, `sort -t' ' -k3,3nr`).

A `freshness-stale:` line is only emitted for a file that **already carries a
stamp** — staleness is measured as days since the stamp date, so a file with no
stamp has no age and cannot be stale.

So the audit queue was drawn entirely from the stamped set. Every cycle picked
one of the same 8 files, re-validated it, re-stamped it, and coverage stayed at
0%. There was no path from "never audited" to "audited". The class was not slow;
it was **closed**.

The tell was uncomfortably direct: `scripts/freshness-inventory.sh` was the top
stale component on 07-31 *and* on 08-09. This cycle was being asked to audit the
inventory script for the second time in nine days while 1013 files had not been
looked at once.

## The general shape

This is the same family as the other findings in this session and the ones
`632-39p3` and `627-cx24` record: **a mechanism that is active, correct at every
step, and measuring the wrong population.** Nothing errors. The advisory ranks
honestly. The audits are real audits. The number it reports — 0% — is accurate,
and it was accurate nine days ago, and nothing in the loop treated an unchanging
0% as a signal that the loop itself was the problem.

A metric that cannot move is worse than a missing metric, because it looks like
diligence.

## Fix

`scripts/freshness-inventory.sh` gains one output line:

```
freshness-next: <relpath> source=<unstamped|stale> seed=<seed>
```

It draws the next audit target from the **unstamped** set first, falling back to
the oldest stamp only when coverage reaches 100%. At 0% coverage the stamped set
is not a sample of the system — it is a sample of what previous audits happened
to touch, and ranking within it answers a question the audit class is not asking.

Selection is deterministic under a printed `FRESHNESS_SEED` (so a cycle is
replayable) and rotates by UTC date (so consecutive cycles advance through the
backlog instead of re-auditing one file). Existing report lines are unchanged —
the grammar is pinned by litmus and consumers keep working.

## Pinned by

Three steps added to `litmus:freshness-inventory-shape`:

- the `freshness-next:` grammar;
- **ANTI-STARVATION** — below 100% coverage the next target must have
  `source=unstamped`. This is the actual regression guard: if it ever fails
  while coverage is under 100%, the path from "never audited" to "audited" has
  been severed again;
- reproducibility under a fixed seed.

## This cycle's audit disposition

Component: `scripts/freshness-inventory.sh`. Verdict: **updated** (stamp
rewritten). Repair rather than discard was the right call here against the
standing discard-over-repair bias — the inventory, grammar, and exit contract
are all sound and consumed by a pinned litmus and by `local-ci.sh`. The defect
was one missing output line, not a stale design.

## Residual (open, filed as 640-iujb)

Coverage is still 0%. One component per cycle against 1013 unstamped files is
~1013 cycles, so the queue is now *open* but not *convergent*. The packet asks
for a rate decision — batch stamping of trivially-auditable components, an
exemption class for generated or vendored files, or an explicit statement that
partial coverage is acceptable and the target is a percentage rather than
completion. That is a scope question the operator owns, not one this loop should
answer by raising its own bar.
