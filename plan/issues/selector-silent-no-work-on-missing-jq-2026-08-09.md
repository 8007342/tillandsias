# Batch selector reported an environment fault as a drained ledger (order 632-retq)

- Date: 2026-08-09
- Host: windows (windows-next)
- Class: `optimization/` — a velocity killer, not a correctness bug in the plan data
- Status: fixed in this commit; one residual left open (see "Residual")

## What happened

`scripts/select-work-batch.sh windows` printed:

```
refused:no-eligible-work:no ready packets for role windows
```

The ledger was not drained. `tillandsias-plan query --status ready --role windows`
returned **7 claimable packets** for this exact host (154, 279, 402, 513, 514,
599-3b9h, 624-su5r). `linux` and `any` refused identically, so the refusal did
not even discriminate by role.

Cause: every projection in the selector is a `jq` call, `jq` is not installed on
the Windows host (already recorded as missing there by
`plan/issues/litmus-corpus-not-host-aware-windows-2026-08-03.md`), and the
flatten carried `2>/dev/null`. jq's absence therefore produced an empty `rows`,
which fell straight into the `no-eligible-work` refusal.

## Why it mattered more than its size suggests

`no-eligible-work` is the greedy `/meta-orchestration` loop's **terminal state** —
the operator's own stop condition for this run was "until the host doesn't have
any eligible work." So the failure did not degrade throughput, it *counterfeited
completion*: a 12-hour greedy loop on this host would have refused, concluded
the plan was empty, and idled to zero while its own role's packets sat ready. A
silent misclassification that impersonates a legitimate terminal state costs the
entire budget, not one cycle.

The general shape, worth recognising elsewhere: an environment fault wearing the
costume of a valid answer. `2>/dev/null` on a load-bearing dependency is where
that costume comes from.

## Fix

`scripts/select-work-batch.sh`:

1. **jq preflight** — refuses `refused:missing-tool:` with an explicit "this is
   NOT a drained ledger" clause before any projection runs.
2. **Parse-failure discrimination** — if `tillandsias-plan` returned more than
   the two bytes of `[]` but the projection yielded no rows, that is
   `refused:parse-failure:` (with the byte count), not `no-eligible-work`. This
   catches the next tooling fault, not just this one.
3. **`TILLANDSIAS_JQ` test seam** — names the binary so the litmus can exercise
   the absent-jq path. Emptying `PATH` cannot test this: it kills the shebang
   before the script runs (`/usr/bin/env: 'bash': No such file or directory`).

`openspec/litmus-tests/litmus-cycle-batch-triage-shape.yaml` gains a negative
control asserting **both** halves — the `missing-tool` token appears *and*
`no-eligible-work` does not. Only the second half catches the regression; a
one-sided assertion would pass against the buggy script.

## Residual (open)

The fix makes the host fail loud; it does not make the host *work*. `jq` is
still absent on Windows, so the selector cannot run here at all, and the greedy
loop has no batch source on this host. Two candidate resolutions, neither taken
here because both exceed a single cycle's blast radius:

- provision `jq` on the Windows host (host change, operator-owned); or
- drop the jq dependency from the selector in favour of a projection
  `tillandsias-plan` emits itself, which would also remove the equivalent
  exposure for `yq`/`ruby` recorded in the 2026-08-03 host-awareness issue.

The second is the better reduction — it deletes a class of host-dependency
rather than satisfying one instance — and is filed as the follow-up packet.
