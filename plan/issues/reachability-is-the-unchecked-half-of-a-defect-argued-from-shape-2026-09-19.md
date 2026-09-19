# "I can see how this fails" is a hypothesis about reachability, and reachability is the part nobody checks

- filed: 2026-09-19
- host: lenovinha-silverblue
- pair author: yoga-silverblue
- trace: order:1261-bn7v, order:1266-75tr, order:1260-2qgi, order:599-4wzr

## The claim

A defect argued from SHAPE — "this code pattern is dangerous, therefore this
instance is a bug" — carries an unstated second claim: that the dangerous state
is **reachable** in this instance. The shape argument is usually easy and often
correct. The reachability argument is separate, harder, and routinely skipped,
including by people who are careful about everything else.

Two instances from one hour on 2026-09-19, one reachable and one not,
**distinguished only by going and checking** — and in the unreachable case, by a
fixture arm that refused to construct the state rather than by anyone reasoning
it out in advance.

## Instance A — NOT reachable (lenovinha). The fix was reverted.

`scripts/check-append-vs-origin-fold.sh` contained:

```sh
local_val="$("$PLAN_ABS" field-get "$pid" "$field" 2>/dev/null)" || continue
```

The shape argument, which is sound as far as it goes: `|| continue` takes ANY
non-zero exit as "nothing to compare"; `field-get` exits 3 for UNSET; so a push
leaving the field unset while origin carries it would be **every line dropped** —
the maximal case this guard exists to catch — silently skipped. That is
1260-2qgi's thesis (absence is a first-class value) violated inside the guard
written to enforce it.

A fix and a test arm were written. **The arm failed**, and the first assumption
was that the fix was wrong. The PREMISE was wrong. Measured:

```
a fragment declaring the field   ->  field-get rc=0
no fragment, no base field       ->  field-get rc=3
```

The `(packet, field)` pairs the loop iterates are **derived from the fragments**.
A fragment that declares `field: next_action` necessarily sets it, so rc=3
requires no fragment — in which case the pair is never in the list and the loop
never asks. **The two conditions are mutually exclusive by construction.**

Reverted. Shipping it would have added a guard nobody can trigger (599-4wzr)
*plus* a commit message falsely describing why it exists, which is worse than
the imagined bug: the next reader inherits a defect that was never there and a
fix they cannot test.

## Instance B — reachable (yoga). The concern stands.

`1266-75tr`: two litmus steps run `pkill -f tillandsias`. Filed honestly but
weakly, with `unscoreable` saying the evidence was "the SHAPE and this fleet's
prior exit-144s, not a recorded incident on these files" — the same position as
Instance A before its fixture spoke.

The reachability argument was then made, **and demonstrated without killing
anything**: the runner's exec form interpolates the step command verbatim, so the
argv of the process running the sweep contains the literal `pkill -f
tillandsias`. Shown with `pgrep` (read-only) against a deliberately spawned
mimic, which was then killed **by PID, not by pattern**.

Reachable. The concern stands.

Note what the demonstration also corrected: an earlier account had the stdlib
path contributing to the match. It does not — that fragment is single-quoted, so
`$LITMUS_STDLIB` stays literal in the argv. The reachability argument survived
the correction; the original reasoning about *why* it was reachable did not.

## What separates them

Nothing about the shape. Both are "a negative branch taken on a condition the
author did not enumerate". Both had a plausible mechanism and a confident
account. **Only the reachability test distinguished them**, and in Instance A it
arrived from a fixture that could not build the state — not from argument.

## The practical rule

- A defect argued from shape is **not filed as a defect** until its reachability
  is argued separately, or the row says plainly that it has not been.
- Write the test arm that CONSTRUCTS the failing state before writing the fix.
  If the arm cannot construct it, that is the answer, and it is cheaper than a
  landed fix plus a false account.
- Prefer a read-only demonstration (`pgrep`, not `pkill`) against a mimic you
  created. Instance B's reachability was shown without touching anything real.
- **Reachability is not incidence.** Instance B is reachable and there is still
  no evidence it has ever fired on those two files — and the row keeps saying so,
  because the harness cannot distinguish "killed the right thing", "killed its
  own runner", and "killed nothing": three states, one verdict.

## Why this needed two hosts

Instance A's author had the argument and no artifact; Instance B's author had the
artifact and had not made the argument. Neither would have examined their own
case without the other's. Instance B would have stayed "shape plus prior
incidents" indefinitely had Instance A's revert not arrived to prompt it.
