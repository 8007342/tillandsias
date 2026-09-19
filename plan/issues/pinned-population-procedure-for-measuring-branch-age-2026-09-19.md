# procedure: measuring the salvage audit against a PINNED population and PINNED baselines

- filed: 2026-09-19
- hosts: lenovinha-silverblue (procedure), yoga-silverblue (three flaws, two additions)
- trace: order:1226-jb8y
- status: PROCEDURE ONLY. Not yet run. Branch age remains UNSUPPORTED.

## Why a procedure needed filing before any run

Two hosts spent an evening trading `is-AHEAD` counts and briefly agreed. That
agreement was **four independent defects cancelling**:

1. **truncated reads** — audits killed by a `timeout` bound, counted anyway;
2. **no completeness check** — nothing in the output was consulted to ask whether
   it had finished;
3. **a mutating ref population** — `fetch --prune` moved the world between runs;
4. **divergent baseline resolution** — one host used `rev-list --before`, the
   other `@{...}`.

Any ONE of these voids the comparison. "We disagreed and found a bug" would be a
better story than what happened, and it is not what happened.

## The baseline trap, named because a later reader will reach for it

**`@{...}` must not appear anywhere in this procedure.** It reads naturally —
`origin/linux-next@{7 days ago}` is the obvious way to say "seven days ago" — and
it resolves through the **reflog**, which is private to each clone and reflects
that clone's fetch history. Measured, same nominal baseline:

```
git rev-list -1 --before='7 days ago' origin/linux-next
  lenovinha  17c0ed0dd
  yoga       17c0ed0dd     <- IDENTICAL across hosts, by construction
git rev-parse 'origin/linux-next@{7 days ago}'
  lenovinha  779685cce
  yoga       edeaff370     <- DIFFERENT on every host; 34 minutes apart
```

`rev-list --before` is a function of the tip and the commit dates, so two hosts
at the same tip agree by construction. `@{...}` is a function of one clone's
fetch history and agrees with nobody — including itself at a different hour.

Naming the trap is cheaper than describing the remedy.

## Procedure

1. **Pin the population.** Snapshot sha/name pairs to `refs.txt` and COMMIT it:
   `git for-each-ref --format='%(objectname) %(refname)' 'refs/remotes/origin/salvage/**' 'refs/remotes/origin/work/**'`
   The population is then a FILE, not a query.
2. **Pin the baselines.** Resolve each baseline ONCE with `rev-list --before`,
   write the SHAs to `baselines.txt`, and COMMIT it. **Record the TIP they were
   resolved against in the same file** — `rev-list` is deterministic *given the
   tip*, so if trunk moves and someone regenerates, the same date expression
   yields different SHAs and the artifact silently stops meaning what it said.
   Pin the input to the pin. No date expressions at run time, on either host.
3. **Build a scratch whose origin RESOLVES.** A local bare repo holding exactly
   `refs.txt`; clone the scratch from it. Objects are present and the audit's own
   fetch succeeds. The rule is **no NETWORK fetch after snapshot** — not "no
   fetch", which would leave the objects absent and the audit empty.
4. **Audit each baseline, and retain everything.** Per run record:
   - the legend count (`grep -c 'Only .ref-may-be-AHEAD'`) — must be **1**
   - the degraded-read count (`grep -c 'could not fetch'`) — must be **0**
   - the audit's **verdict line verbatim**, not merely `Nf` parsed out of it
   - the three RAW label counts, and the corrected ones (legend offset is +1 on
     `is-AHEAD`, +1 on `ref-may-be-AHEAD`, +0 on `ABSENT-from`, validated by
     corrected sum == Nf)
   - **the raw output, retained.** Not summarised and discarded.
   Discard any run with legend != 1 or note != 0.
5. **Both hosts run step 4 against the same committed `refs.txt` and
   `baselines.txt`.**

## Two completeness questions, and they are different

- The **legend** proves the ARTIFACT IS WHOLE — did I read all of it.
- The **`could not fetch` check** proves the WORLD WAS COMPLETE — was there all
  of it to read.

A run can be whole and degraded at once. Neither test alone catches that, and
nothing filed before this row asked the second question at all.

Ordering matters in step 3: the resolvable local origin makes the note never
fire, and the grep then CONFIRMS rather than rescues. *A check that only ever
catches is indistinguishable from a check that never fires.*

## Retention is a requirement, not a note

One host's artifacts could be classified after the fact — complete, truncated,
still-running — only because they were KEPT. The other's sweeps are permanently
unauditable because the tool summarised and discarded its input. **An instrument
that discards the evidence required to validate the instrument produces numbers
nobody can audit, including its author twenty minutes later.**

## What this does not do

It does not settle branch age. It makes an answer *possible* by removing the four
defects above. Until a run passes step 4's discard rules on both hosts, branch
age remains **unsupported** — which is a stable state, not a pending one.
