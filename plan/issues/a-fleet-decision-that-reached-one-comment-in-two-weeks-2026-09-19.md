# a diagnosed mechanism, two ranked remedies and a named principle reached one comment in two weeks

- filed: 2026-09-19
- hosts: lenovinha-silverblue, yoga-silverblue
- trace: order:1266-75tr, order:1252-fg9e
- precedent: `plan/index.yaml`, the esme-windows entry at ts `2026-09-04T16:30:18Z`

## The precedent

On **2026-09-04** — two weeks before this was rediscovered — the ledger recorded,
from esme-windows on esmeraldinha:

- the **mechanism**: a `pgrep -f 'build.sh'` disappearance arm "could never fire,
  because `pgrep -f` matches its own `sh -c` wrapper, so the process was always
  found and a gate that died silently would have looked identical to one still
  running". Caught on an idle host "where the command printed two matches, both
  itself".
- **two remedies, ranked**: bracket a character (`pgrep -f '[b]uild.sh'`), or —
  "preferred for the method the fleet copies because it is harder to get subtly
  wrong" — `/proc/loadavg` plus the log's mtime, "which needs no self-exclusion
  and is what told the truth here".
- the **principle**: *"a check that cannot fail is not a check."*

Diagnosed, remedied, ranked, and named. Nothing about it was unresolved.

## Where it got to

```
grep -rlE 'self-exclusion|cannot match itself|a check that cannot fail' \
    --include=*.sh --include=*.yaml scripts openspec
  -> scripts/local-ci.sh
```

One file. And in that file it is a single comment referencing the principle —
not the remedy, not a guard, not a check:

scripts/local-ci.sh:1722 — `# litmus scar at the bottom of this file: a check that cannot fail.` <!-- cite-ok: the line number IS the finding: this is the sole occurrence of the 2026-09-04 principle anywhere outside the ledger, and the point is that there is exactly one and it is a comment. Locate it by the stable string "a check that cannot fail"; the number will drift, which is expected and does not affect the claim. -->

It did **not** reach:

- the two litmus steps carrying the defect (`litmus-ca-ephemeral.yaml:34`,
  `litmus-mount-cleanup.yaml:34`) — the only unbracketed `pkill -f` in a corpus
  where four sibling sites **are** bracketed, deliberately;
- any guard capable of detecting the shape;
- three people who hit that exact shape on 2026-09-19, twice while documenting it
  and once while attempting to verify a mitigation for it.

## What was rediscovered, independently, in one evening

- **file growth** as a liveness signal that cannot self-match, because it never
  names the process;
- the **verdict line** as a completeness signal, the producer's own terminal
  statement rather than a proxy;
- the **`could not fetch` check**, reading what the tool said about its own inputs.

Three instruments, one principle — *stop asking the subject about itself* — which
is the 2026-09-04 entry's "needs no self-exclusion", restated. Two hosts cited
**each other** for it. Neither cited the ledger, because neither read it.

## The actual defect

**A decision recorded in the ledger is not a decision that has reached anything.**
This one had every property we tell ourselves makes a finding durable: a measured
mechanism, a reproduction, ranked remedies, a quotable principle, and a permanent
home in an append-only record. Two weeks later its remedy was absent from the two
call sites that needed it, and three engineers rediscovered its principle by
walking into it.

The ledger is not the problem — the entry is exemplary and was found in seconds
once someone looked. **Nobody looked**, because nothing pointed from a call site
to the decision about it.

## Exit criteria

- A decision that names a remedy for a **code shape** is either enforced by a
  guard or carries an explicit statement that it is unenforced and why. Prose in
  a ledger entry is not a control — the same prose-versus-enforceability defect
  already recorded for specs requiring SELinux, one layer up.
- The two unbracketed sites adopt the sibling pattern already in the corpus at
  `litmus-expert-serve-endpoint-shape.yaml:86`: **kill by PID from a pidfile the
  step wrote, with the bracketed pattern only as a backstop.** That is strictly
  better than bracketing alone — it does not depend on the pattern being
  unmatched by the matcher, it depends on knowing which process you meant.
- NEGATIVE CONTROL: the four already-bracketed sites keep working unchanged. A
  sweep that rewrites all six identically has replaced a considered pattern with
  a uniform one.

## What this row does not claim

That a guard would have prevented the three ad-hoc occurrences. All three were
typed at a prompt, not committed call sites, and a guard over the corpus does not
reach a shell. Those remain the population where neither construction nor
documentation has worked, and this row does not pretend otherwise.
